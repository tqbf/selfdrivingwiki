//! The shared fixture corpus (Protocol/app-daemon/fixtures/corpus.json):
//! one manifest drives BOTH interop roles. Decoding maps the JSON into
//! proto values; comparison is by decoded known-field values and presence,
//! never raw bytes (Protobuf serialization is not canonical).

use std::path::Path;

use prost::Message;
use serde::Deserialize;

use crate::proto as v1;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Corpus {
    #[allow(dead_code)] // the manifest's own version; retained for drift checks
    pub version: u32,
    pub admission: Admission,
    pub capabilities: Capabilities,
    pub cases: Vec<Case>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Admission {
    pub bootstrap: String,
    #[serde(rename = "sessionHex")]
    pub session_hex: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    pub contract_version: u32,
    #[serde(rename = "daemonInstanceID")]
    pub daemon_instance_id: String,
    pub capabilities: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Case {
    pub id: String,
    pub operation: String,
    #[serde(default)]
    pub reply: Option<Reply>,
    #[serde(default)]
    pub event: Option<EventCase>,
    #[serde(default)]
    pub error: Option<ErrorCase>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reply {
    pub wikis: Vec<WikiCase>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WikiCase {
    pub id: String,
    #[serde(rename = "displayName")]
    pub display_name: String,
    pub created_at: String,
    pub last_used_at: String,
    #[serde(rename = "homePageID")]
    pub home_page_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventCase {
    pub kind: String,
    #[serde(rename = "wikiID")]
    pub wiki_id: String,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorCase {
    pub grpc_code: String,
    pub details_code: String,
    pub message: String,
    pub retryable: bool,
    #[serde(rename = "daemonInstanceID")]
    pub daemon_instance_id: String,
}

pub fn load(path: &Path) -> Result<Corpus, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("corpus read failed ({}): {e}", path.display()))?;
    let corpus: Corpus = serde_json::from_str(&text)
        .map_err(|e| format!("corpus decode failed: {e}"))?;
    Ok(corpus)
}

impl Corpus {
    pub fn case(&self, id: &str) -> Result<&Case, String> {
        self.cases
            .iter()
            .find(|c| c.id == id)
            .ok_or_else(|| format!("corpus case '{id}' not found"))
    }

    /// The wire descriptor for one corpus wiki entry (values + presence).
    pub fn descriptor(case_wiki: &WikiCase) -> Result<v1::WikiDescriptor, String> {
        Ok(v1::WikiDescriptor {
            id: Some(v1::WikiId { value: case_wiki.id.clone() }),
            display_name: case_wiki.display_name.clone(),
            created_at: Some(parse_timestamp(&case_wiki.created_at)?),
            last_used_at: Some(parse_timestamp(&case_wiki.last_used_at)?),
            home_page_id: match &case_wiki.home_page_id {
                Some(value) => Some(v1::PageId { value: value.clone() }),
                None => None,
            },
        })
    }

    /// The wire registry event for one corpus event entry.
    pub fn registry_event(case_event: &EventCase) -> Result<v1::RegistryEvent, String> {
        let kind = match case_event.kind.as_str() {
            "CREATED" => v1::registry_event::Kind::Created,
            "RENAMED" => v1::registry_event::Kind::Renamed,
            "DELETED" => v1::registry_event::Kind::Deleted,
            other => return Err(format!("unknown corpus event kind '{other}'")),
        };
        Ok(v1::RegistryEvent {
            kind: kind as i32,
            wiki_id: Some(v1::WikiId { value: case_event.wiki_id.clone() }),
            display_name: case_event.display_name.clone(),
        })
    }

    /// The typed status for one corpus error entry: gRPC code + packed
    /// versioned details. tonic 0.14 carries rich details in a dedicated
    /// `details` field (`grpc-status-details-bin` on the wire); passing the
    /// reserved header as user metadata would be silently ignored.
    pub fn error_status(case_error: &ErrorCase) -> Result<tonic::Status, String> {
        let code = grpc_code(case_error.grpc_code.as_str())?;
        let details_code = details_code(case_error.details_code.as_str())?;
        let details = v1::ErrorDetails {
            version: 1,
            code: details_code,
            message: case_error.message.clone(),
            retryable: case_error.retryable,
            daemon_instance_id: case_error.daemon_instance_id.clone(),
        };
        let rpc_status = RpcStatus {
            code: code as i32,
            message: case_error.message.clone(),
            details: vec![prost_types::Any {
                type_url: "type.googleapis.com/wikid.appdaemon.v1.ErrorDetails".to_string(),
                value: details.encode_to_vec(),
            }],
        };
        Ok(tonic::Status::with_details(
            code,
            case_error.message.clone(),
            rpc_status.encode_to_vec().into(),
        ))
    }
}

/// The minimal google.rpc.Status carrier (hand-declared; the contract has
/// no protobuf dependency on googleapis beyond well-known Any).
#[derive(Clone, PartialEq, prost::Message)]
pub struct RpcStatus {
    #[prost(int32, tag = "1")]
    pub code: i32,
    #[prost(string, tag = "2")]
    pub message: String,
    #[prost(message, repeated, tag = "3")]
    pub details: Vec<prost_types::Any>,
}

/// Pull the packed `ErrorDetails` out of a received status: tonic 0.14's
/// dedicated `details` field first (that is where the wire header lands),
/// falling back to explicit bin metadata for older peers.
pub fn unpack_details(status: &tonic::Status) -> Option<v1::ErrorDetails> {
    let mut candidates: Vec<Vec<u8>> = Vec::new();
    if !status.details().is_empty() {
        candidates.push(status.details().to_vec());
    }
    if let Some(value) = status.metadata().get_bin("grpc-status-details-bin") {
        if let Ok(bytes) = value.to_bytes() {
            candidates.push(bytes.to_vec());
        }
    }
    for bytes in candidates {
        if let Ok(rpc_status) = RpcStatus::decode(bytes.as_slice()) {
            for detail in rpc_status.details {
                if detail.type_url.ends_with("wikid.appdaemon.v1.ErrorDetails") {
                    if let Ok(details) = v1::ErrorDetails::decode(detail.value.as_slice()) {
                        return Some(details);
                    }
                }
            }
        }
    }
    None
}

fn grpc_code(name: &str) -> Result<tonic::Code, String> {
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

fn details_code(name: &str) -> Result<i32, String> {
    match name {
        "INVALID_REQUEST" => Ok(v1::error_details::Code::InvalidRequest as i32),
        "UNAUTHENTICATED" => Ok(v1::error_details::Code::Unauthenticated as i32),
        "CAPABILITY_MISMATCH" => Ok(v1::error_details::Code::CapabilityMismatch as i32),
        "RESYNC_REQUIRED" => Ok(v1::error_details::Code::ResyncRequired as i32),
        "WIKI_NOT_FOUND" => Ok(v1::error_details::Code::WikiNotFound as i32),
        "UNAVAILABLE" => Ok(v1::error_details::Code::Unavailable as i32),
        "RESOURCE_EXHAUSTED" => Ok(v1::error_details::Code::ResourceExhausted as i32),
        "DEADLINE_EXCEEDED" => Ok(v1::error_details::Code::DeadlineExceeded as i32),
        other => Err(format!("unknown corpus detailsCode '{other}'")),
    }
}

/// Parse the corpus's RFC3339 `Z` timestamps (fixed format; the corpus is
/// authored with whole seconds UTC) into `prost_types::Timestamp`.
pub fn parse_timestamp(text: &str) -> Result<prost_types::Timestamp, String> {
    let bytes = text.as_bytes();
    let fail = || format!("unsupported corpus timestamp '{text}' (expect YYYY-MM-DDTHH:MM:SSZ)");
    if bytes.len() != 20 || bytes[4] != b'-' || bytes[7] != b'-' || bytes[10] != b'T'
        || bytes[13] != b':' || bytes[16] != b':' || bytes[19] != b'Z'
    {
        return Err(fail());
    }
    let num = |range: std::ops::Range<usize>| -> Result<i64, String> {
        text[range].parse::<i64>().map_err(|_| fail())
    };
    let (year, month, day, hour, minute, second) = (
        num(0..4)?, num(5..7)?, num(8..10)?, num(11..13)?, num(14..16)?, num(17..19)?,
    );
    // Howard Hinnant's days_from_civil (public domain algorithm shape).
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let m = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * m + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Ok(prost_types::Timestamp {
        seconds: days * 86_400 + hour * 3600 + minute * 60 + second,
        nanos: 0,
    })
}

/// Format a prost timestamp back to the corpus's fixed RFC3339 shape.
pub fn format_timestamp(timestamp: &prost_types::Timestamp) -> String {
    let total = timestamp.seconds;
    let days = total.div_euclid(86_400);
    let secs_of_day = total.rem_euclid(86_400);
    // civil_from_days (same algorithm family, inverted).
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year,
        m,
        d,
        secs_of_day / 3600,
        (secs_of_day % 3600) / 60,
        secs_of_day % 60
    )
}
