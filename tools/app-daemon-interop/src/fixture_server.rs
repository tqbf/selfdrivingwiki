//! The fixture SERVER role: serves the contract from the corpus manifest so
//! the PRODUCTION Swift client can be validated against a non-Swift peer.

use std::path::PathBuf;
use std::pin::Pin;

use tokio::net::UnixListener;
use tokio_stream::wrappers::UnixListenerStream;
use tonic::transport::Server;
use tonic::{Request, Response, Status};

use crate::corpus::{self, Corpus};
use crate::proto as v1;
use crate::proto::app_daemon_server::{AppDaemon, AppDaemonServer};
use crate::proto::{
    AdmitSessionReply, AdmitSessionRequest, DaemonEvent, GetCapabilitiesReply,
    GetCapabilitiesRequest, ListWikisReply, ListWikisRequest, SubscribeEventsRequest,
};

/// The streamed response type for SubscribeEvents.
pub type EventStream = Pin<Box<dyn tokio_stream::Stream<Item = Result<DaemonEvent, Status>> + Send + 'static>>;

#[derive(Clone)]
pub struct FixtureServer {
    corpus: Corpus,
    /// The corpus listWikis case to serve.
    list_case: String,
    /// When set, every RPC fails with this corpus error case.
    serve_error: Option<String>,
    /// Serve a contract version that is incompatible with the client build.
    incompatible: bool,
    /// Pad the ListWikis reply beyond the 4 MiB declared bound.
    oversize_response: bool,
}

/// Serve-mode toggles (flag-driven; the Swift tests pick scenarios).
#[derive(Clone, Debug, Default)]
pub struct ServeOptions {
    pub case: Option<String>,
    pub serve_error: Option<String>,
    pub incompatible: bool,
    pub oversize_response: bool,
}

impl FixtureServer {
    pub fn options(options: &ServeOptions, corpus: Corpus) -> Self {
        Self {
            corpus,
            list_case: options.case.clone().unwrap_or_else(|| "list-wikis-basic".into()),
            serve_error: options.serve_error.clone(),
            incompatible: options.incompatible,
            oversize_response: options.oversize_response,
        }
    }

    fn serve_error_status(&self) -> Option<Status> {
        let case_id = self.serve_error.as_ref()?;
        let case = self.corpus.case(case_id).ok()?;
        let error = case.error.as_ref()?;
        Corpus::error_status(error).ok()
    }
}

#[tonic::async_trait]
impl AppDaemon for FixtureServer {
    type SubscribeEventsStream = EventStream;

    async fn admit_session(
        &self,
        request: Request<AdmitSessionRequest>,
    ) -> Result<Response<AdmitSessionReply>, Status> {
        // Admission is NOT error-injected: the probe needs a session before
        // it can observe the injected workload failure.
        let bearer = bearer_of(request.metadata());
        if bearer.as_deref() != Some(self.corpus.admission.bootstrap.as_str()) {
            return Err(unauthenticated("Missing, expired, or revoked admission credential"));
        }
        let session_hex = self.corpus.admission.session_hex.clone();
        Ok(Response::new(AdmitSessionReply {
            session_credential: hex_to_bytes(&session_hex),
            daemon_instance_id: self.corpus.capabilities.daemon_instance_id.clone(),
            admitted_at: None,
        }))
    }

    async fn get_capabilities(
        &self,
        request: Request<GetCapabilitiesRequest>,
    ) -> Result<Response<GetCapabilitiesReply>, Status> {
        // Capabilities stay healthy under --serve-error: the injected
        // failure targets the workload RPC (see list_wikis).
        let bearer = bearer_of(request.metadata());
        if bearer.is_none() {
            return Err(unauthenticated("authorization metadata missing"));
        }
        Ok(Response::new(GetCapabilitiesReply {
            contract_version: if self.incompatible {
                self.corpus.capabilities.contract_version + 1
            } else {
                self.corpus.capabilities.contract_version
            },
            daemon_instance_id: self.corpus.capabilities.daemon_instance_id.clone(),
            capabilities: self.corpus.capabilities.capabilities.clone(),
            served_at: None,
        }))
    }

    async fn list_wikis(
        &self,
        request: Request<ListWikisRequest>,
    ) -> Result<Response<ListWikisReply>, Status> {
        // Error injection targets the workload RPC the probe points
        // --expect-error at; admission and the capabilities handshake stay
        // healthy so the probe can reach the injected failure.
        if let Some(status) = self.serve_error_status() {
            return Err(status);
        }
        let bearer = bearer_of(request.metadata());
        if bearer.is_none() {
            return Err(unauthenticated("authorization metadata missing"));
        }
        let case = self
            .corpus
            .case(&self.list_case)
            .map_err(|e| Status::internal(e))?;
        let reply = case.reply.clone().ok_or_else(|| {
            Status::internal(format!("corpus case '{}' has no reply", case.id))
        })?;
        let mut wikis = Vec::new();
        for wiki in reply.wikis {
            wikis.push(corpus::Corpus::descriptor(&wiki).map_err(Status::internal)?);
        }
        if self.oversize_response {
            // Pad the LAST wiki's display name beyond the declared 4 MiB
            // single-message bound. The client must reject with
            // RESOURCE_EXHAUSTED per the bounds rule.
            if let Some(last) = wikis.last_mut() {
                let padding = "p".repeat(5 * 1024 * 1024);
                last.display_name = format!("{}{}", last.display_name, padding);
            }
        }
        Ok(Response::new(ListWikisReply { wikis }))
    }


    async fn subscribe_events(
        &self,
        request: Request<SubscribeEventsRequest>,
    ) -> Result<Response<EventStream>, Status> {
        if let Some(status) = self.serve_error_status() {
            return Err(status);
        }
        let bearer = bearer_of(request.metadata());
        if bearer.is_none() {
            return Err(unauthenticated("authorization metadata missing"));
        }
        let requested = request.into_inner().families;
        // First slice: REGISTRY only — reject anything else BEFORE the
        // stream exists so a client never believes a family is flowing.
        for family in requested {
            if family != v1::EventFamily::Registry as i32 {
                return Err(corpus::Corpus::error_status(&corpus::ErrorCase {
                    grpc_code: "InvalidArgument".into(),
                    details_code: "INVALID_REQUEST".into(),
                    message: format!(
                        "Event family not served by this contract version: {family}"
                    ),
                    retryable: false,
                    daemon_instance_id: self.corpus.capabilities.daemon_instance_id.clone(),
                })
                .map_err(|e| Status::internal(e))?);
            }
        }

        // Stream the corpus's event cases in order, stamped with a
        // monotonically increasing sequence.
        let mut events = Vec::new();
        let mut sequence: u64 = 0;
        for case in &self.corpus.cases {
            if case.operation != "event" {
                continue;
            }
            let Some(event) = case.event.as_ref() else { continue };
            sequence += 1;
            events.push(DaemonEvent {
                sequence,
                event: Some(v1::daemon_event::Event::Registry(
                    corpus::Corpus::registry_event(event).map_err(Status::internal)?,
                )),
            });
        }
        let stream: EventStream =
            Box::pin(tokio_stream::iter(events.into_iter().map(Ok)));
        Ok(Response::new(stream))
    }
}

/// Bind the socket path (removing a stale file: the fixture server owns its
/// private temp path) and serve until cancelled.
pub async fn serve(socket: PathBuf, server: FixtureServer) -> Result<(), String> {
    if let Some(parent) = socket.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("mkdir failed for {}: {e}", parent.display()))?;
    }
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket)
        .map_err(|e| format!("bind failed for {}: {e}", socket.display()))?;
    let incoming = UnixListenerStream::new(listener);
    Server::builder()
        .add_service(AppDaemonServer::new(server))
        .serve_with_incoming(incoming)
        .await
        .map_err(|e| format!("serve failed: {e}"))
}

fn bearer_of(metadata: &tonic::metadata::MetadataMap) -> Option<String> {
    let value = metadata.get("authorization")?.to_str().ok()?;
    let rest = value.strip_prefix("Bearer ").or_else(|| value.strip_prefix("bearer "))?;
    Some(rest.trim().to_string())
}

fn unauthenticated(message: &str) -> Status {
    corpus::Corpus::error_status(&corpus::ErrorCase {
        grpc_code: "Unauthenticated".into(),
        details_code: "UNAUTHENTICATED".into(),
        message: message.to_string(),
        retryable: false,
        daemon_instance_id: "fixture-instance".into(),
    })
    .unwrap_or_else(|_| Status::unauthenticated(message))
}

fn hex_to_bytes(hex: &str) -> Vec<u8> {
    (0..hex.len() / 2)
        .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap_or(0))
        .collect()
}
