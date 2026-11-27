//! The fixture CLIENT role (probe): validates the PRODUCTION Swift server
//! against the same corpus — admission, capabilities, registry read, typed
//! events, typed errors, and the oversized-response bound. Exit code 0
//! means every check passed; failures print the reason and exit 1.

use std::path::PathBuf;

use hyper_util::rt::TokioIo;
use tower::service_fn;
use tonic::transport::{Endpoint, Uri};
use tonic::metadata::MetadataValue;
use tonic::Request;

use crate::corpus;
use crate::proto::app_daemon_client::AppDaemonClient;
use crate::proto::{
    AdmitSessionRequest, GetCapabilitiesRequest, ListWikisRequest, SubscribeEventsRequest,
};

const MAX_MESSAGE_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct ProbeArgs {
    pub socket: PathBuf,
    pub corpus_path: PathBuf,
    pub list_case: String,
    /// When set: expect ListWikis to fail with this corpus error case and
    /// verify the decoded details.
    pub expect_error: Option<String>,
    /// Expect the ListWikis reply to exceed the declared bound and fail
    /// with RESOURCE_EXHAUSTED.
    pub expect_oversize: bool,
    /// Expect the capabilities handshake to fail (incompatible contract
    /// version) with CAPABILITY_MISMATCH.
    pub expect_incompatible: bool,
}

pub async fn run(args: ProbeArgs) -> Result<(), String> {
    let corpus = corpus::load(&args.corpus_path)?;

    let socket = args.socket.clone();
    let channel = Endpoint::from_shared("http://localhost".to_string())
        .map_err(|e| format!("endpoint build failed: {e}"))?
        .connect_with_connector(service_fn(move |_: Uri| {
            let socket = socket.clone();
            async move {
                let stream = tokio::net::UnixStream::connect(socket).await?;
                Ok::<TokioIo<tokio::net::UnixStream>, std::io::Error>(TokioIo::new(stream))
            }
        }))
        .await
        .map_err(|e| format!("channel connect failed: {e}"))?;
    let mut client =
        AppDaemonClient::new(channel).max_decoding_message_size(MAX_MESSAGE_BYTES);

    // 1. Admission: bootstrap → session bearer (idempotent reply shape).
    let bootstrap = MetadataValue::try_from(format!(
        "Bearer {}",
        corpus.admission.bootstrap
    ).as_str())
    .map_err(|e| format!("bootstrap metadata build failed: {e}"))?;
    let mut request = Request::new(AdmitSessionRequest {});
    request.metadata_mut().insert("authorization", bootstrap);
    let admit = client
        .admit_session(request)
        .await
        .map_err(|e| format!("admit_session failed: {e}"))?;
    let session_hex = bytes_to_hex(&admit.into_inner().session_credential);
    check(
        session_hex == corpus.admission.session_hex,
        format!(
            "session credential mismatch: got {session_hex}, want {}",
            corpus.admission.session_hex
        ),
    )?;

    // 2. Capabilities handshake.
    let bearer = bearer_metadata(&corpus.admission.session_hex)?;
    let mut request = Request::new(GetCapabilitiesRequest {});
    request.metadata_mut().insert("authorization", bearer.clone());
    let capabilities = client.get_capabilities(request).await;
    if args.expect_incompatible {
        // The mismatch gate is CLIENT-side: a server that answers with the
        // WRONG version must be detected as a typed failure by the caller.
        // The probe verifies it can detect exactly that: Ok with a matching
        // version is a FAILURE of this expectation.
        match capabilities {
            Err(status) => {
                let detected = corpus::unpack_details(&status)
                    .map(|d| {
                        d.code == crate::proto::error_details::Code::CapabilityMismatch as i32
                    })
                    .unwrap_or(false)
                    || status.code() == tonic::Code::FailedPrecondition;
                check(
                    detected,
                    format!(
                        "incompatible capabilities must surface CAPABILITY_MISMATCH, got {status:?}"
                    ),
                )?;
            }
            Ok(reply) => check(
                reply.into_inner().contract_version != corpus.capabilities.contract_version,
                "expected incompatible capabilities (handshake answered with the \
                 expected-compatible version)"
                    .to_string(),
            )?,
        }
        return Ok(());
    }
    let capabilities = capabilities
        .map_err(|e| format!("get_capabilities failed: {e}"))?
        .into_inner();
    check(
        capabilities.contract_version == corpus.capabilities.contract_version,
        format!(
            "contract version mismatch: got {}, want {}",
            capabilities.contract_version, corpus.capabilities.contract_version
        ),
    )?;
    check(
        capabilities.daemon_instance_id == corpus.capabilities.daemon_instance_id,
        format!(
            "instance id mismatch: got '{}', want '{}'",
            capabilities.daemon_instance_id, corpus.capabilities.daemon_instance_id
        ),
    )?;
    check(
        capabilities.capabilities == corpus.capabilities.capabilities,
        format!(
            "capabilities mismatch: got {:?}, want {:?}",
            capabilities.capabilities, corpus.capabilities.capabilities
        ),
    )?;

    // 3. Registry read: decoded values AND presence against the corpus.
    if args.expect_error.is_some() || args.expect_oversize {
        let mut request = Request::new(ListWikisRequest {});
        request.metadata_mut().insert("authorization", bearer.clone());
        let result = client.list_wikis(request).await;
        if let Some(case_id) = args.expect_error.as_ref() {
            let case = corpus.case(case_id)?;
            let error = case
                .error
                .as_ref()
                .ok_or_else(|| format!("corpus case '{case_id}' has no error"))?;
            let status = match &result {
                Err(status) => status.clone(),
                Ok(_) => {
                    return Err(format!(
                        "expected corpus error '{case_id}' but ListWikis succeeded"
                    ))
                }
            };
            // Status is consumed below only via references; keep `result`
            // alive for the oversize branch.
            let _ = &result;
            check(
                status.code() == grpc_code_of(error.grpc_code.as_str())?,
                format!(
                    "grpc code mismatch: got {:?}, want {}",
                    status.code(),
                    error.grpc_code
                ),
            )?;
            let details = corpus::unpack_details(&status).ok_or(
                "error status carries no decodable ErrorDetails",
            )?;
            // The typed CODE is the dispatch key — verify it explicitly,
            // not just the prose fields around it.
            check(
                details.code == details_code_of(error.details_code.as_str())?,
                format!(
                    "details code mismatch: got {}, want {}",
                    details.code, error.details_code
                ),
            )?;
            check(
                details.version == 1,
                format!("details version mismatch: got {}", details.version),
            )?;
            check(
                details.message == error.message,
                format!(
                    "details message mismatch: got '{}', want '{}'",
                    details.message, error.message
                ),
            )?;
            check(
                details.daemon_instance_id == error.daemon_instance_id,
                format!(
                    "details instance mismatch: got '{}', want '{}'",
                    details.daemon_instance_id, error.daemon_instance_id
                ),
            )?;
            check(
                !details.retryable && !error.retryable,
                "error retryability mismatch".to_string(),
            )?;
        }
        if args.expect_oversize {
            // tonic reports the enforced decode limit as OutOfRange; grpc-swift
            // reports the same bound as ResourceExhausted. The contract's
            // requirement is that the oversized message FAILS at the declared
            // bound — either code is a predictable rejection.
            let rejected = match &result {
                Err(status) => matches!(
                    status.code(),
                    tonic::Code::ResourceExhausted | tonic::Code::OutOfRange
                ),
                Ok(_) => false,
            };
            check(
                rejected,
                "oversized reply must fail at the declared bound \
                 (ResourceExhausted/OutOfRange)"
                    .to_string(),
            )?;
        }
        return Ok(());
    }

    let mut request = Request::new(ListWikisRequest {});
    request.metadata_mut().insert("authorization", bearer.clone());
    let reply = client
        .list_wikis(request)
        .await
        .map_err(|e| format!("list_wikis failed: {e}"))?
        .into_inner();
    let case = corpus.case(&args.list_case)?;
    let expected = case
        .reply
        .as_ref()
        .ok_or_else(|| format!("corpus case '{}' has no reply", case.id))?;
    check(
        reply.wikis.len() == expected.wikis.len(),
        format!(
            "wiki count mismatch: got {}, want {}",
            reply.wikis.len(),
            expected.wikis.len()
        ),
    )?;
    for (wire, want) in reply.wikis.iter().zip(expected.wikis.iter()) {
        let want_proto = corpus::Corpus::descriptor(want).map_err(|e| e)?;
        check(
            wire.id.as_ref().map(|i| &i.value) == want_proto.id.as_ref().map(|i| &i.value),
            format!(
                "wiki id mismatch: got {:?}, want {:?}",
                wire.id.as_ref().map(|i| &i.value),
                want_proto.id.as_ref().map(|i| &i.value)
            ),
        )?;
        check(
            wire.display_name == want_proto.display_name,
            format!(
                "displayName mismatch: got '{}', want '{}'",
                wire.display_name, want_proto.display_name
            ),
        )?;
        // Presence comparison: hasCreated/hasLastUsed/hasHomePageID.
        check(
            wire.created_at.is_some() == want_proto.created_at.is_some(),
            "createdAt presence mismatch".to_string(),
        )?;
        if let (Some(wire_ts), Some(want_ts)) = (wire.created_at.as_ref(), want_proto.created_at.as_ref()) {
            check(
                corpus::format_timestamp(wire_ts) == corpus::format_timestamp(want_ts),
                format!(
                    "createdAt mismatch: got {}, want {}",
                    corpus::format_timestamp(wire_ts),
                    corpus::format_timestamp(want_ts)
                ),
            )?;
        }
        check(
            wire.home_page_id.is_some() == want_proto.home_page_id.is_some(),
            "homePageID presence mismatch".to_string(),
        )?;
        if let (Some(wire_page), Some(want_page)) =
            (wire.home_page_id.as_ref(), want_proto.home_page_id.as_ref())
        {
            check(
                wire_page.value == want_page.value,
                format!(
                    "homePageID mismatch: got '{}', want '{}'",
                    wire_page.value, want_page.value
                ),
            )?;
        }
    }

    // 4. Typed events: subscribe and consume every corpus event case.
    let mut request = Request::new(SubscribeEventsRequest {
        families: vec![crate::proto::EventFamily::Registry as i32],
    });
    request.metadata_mut().insert("authorization", bearer);
    let mut stream = client
        .subscribe_events(request)
        .await
        .map_err(|e| format!("subscribe_events failed: {e}"))?
        .into_inner();
    let mut sequence: u64 = 0;
    for case in corpus.cases.iter().filter(|c| c.operation == "event") {
        let want = case
            .event
            .as_ref()
            .ok_or_else(|| format!("corpus event case '{}' has no event", case.id))?;
        let next = stream
            .message()
            .await
            .map_err(|e| format!("event stream failed: {e}"))?
            .ok_or_else(|| format!("event stream ended before corpus event '{}'", case.id))?;
        sequence += 1;
        check(
            next.sequence == sequence,
            format!(
                "event sequence mismatch: got {}, want {sequence}",
                next.sequence
            ),
        )?;
        let registry = match next.event {
            Some(crate::proto::daemon_event::Event::Registry(event)) => event,
            other => return Err(format!("event case '{}' carried a non-registry event: {other:?}", case.id)),
        };
        let want_event = corpus::Corpus::registry_event(want).map_err(|e| e)?;
        check(
            registry.kind == want_event.kind,
            format!(
                "event kind mismatch for '{}': got {}, want {}",
                case.id, registry.kind, want_event.kind
            ),
        )?;
        check(
            registry.wiki_id.as_ref().map(|w| &w.value)
                == want_event.wiki_id.as_ref().map(|w| &w.value),
            format!("event wikiID mismatch for '{}'", case.id),
        )?;
        check(
            registry.display_name.is_some() == want_event.display_name.is_some(),
            format!("event displayName presence mismatch for '{}'", case.id),
        )?;
        if registry.display_name != want_event.display_name {
            return Err(format!("event displayName mismatch for '{}'", case.id));
        }
    }

    Ok(())
}

fn check(condition: bool, message: String) -> Result<(), String> {
    if condition {
        Ok(())
    } else {
        Err(message)
    }
}

fn grpc_code_of(name: &str) -> Result<tonic::Code, String> {
    match name {
        "InvalidArgument" => Ok(tonic::Code::InvalidArgument),
        "NotFound" => Ok(tonic::Code::NotFound),
        "FailedPrecondition" => Ok(tonic::Code::FailedPrecondition),
        "Unavailable" => Ok(tonic::Code::Unavailable),
        "ResourceExhausted" => Ok(tonic::Code::ResourceExhausted),
        "Unauthenticated" => Ok(tonic::Code::Unauthenticated),
        "DeadlineExceeded" => Ok(tonic::Code::DeadlineExceeded),
        other => Err(format!("unknown corpus grpcCode '{other}'")),
    }
}

fn details_code_of(name: &str) -> Result<i32, String> {
    use crate::proto::error_details::Code;
    match name {
        "INVALID_REQUEST" => Ok(Code::InvalidRequest as i32),
        "UNAUTHENTICATED" => Ok(Code::Unauthenticated as i32),
        "CAPABILITY_MISMATCH" => Ok(Code::CapabilityMismatch as i32),
        "RESYNC_REQUIRED" => Ok(Code::ResyncRequired as i32),
        "WIKI_NOT_FOUND" => Ok(Code::WikiNotFound as i32),
        "UNAVAILABLE" => Ok(Code::Unavailable as i32),
        "RESOURCE_EXHAUSTED" => Ok(Code::ResourceExhausted as i32),
        "DEADLINE_EXCEEDED" => Ok(Code::DeadlineExceeded as i32),
        other => Err(format!("unknown corpus detailsCode '{other}'")),
    }
}

fn bearer_metadata(hex: &str) -> Result<MetadataValue<tonic::metadata::Ascii>, String> {
    MetadataValue::try_from(format!("Bearer {hex}").as_str())
        .map_err(|e| format!("bearer metadata build failed: {e}"))
}

fn bytes_to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
