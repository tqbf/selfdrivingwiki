//! Codegen for the app–daemon interop peer: Rust bindings are generated at
//! crate build time from the SAME schemas the Swift side uses
//! (Protocol/app-daemon/proto). No drift is possible; the make target passes
//! the verified protoc path via `PROTOC`.
//!
//! The well-known types (google/protobuf/timestamp.proto) come from the
//! pinned protoc distribution's include directory, also passed via the make
//! target (`PROTOC_INCLUDE`).

use std::path::{Path, PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR")?);
    let proto_root = manifest_dir
        .join("../../Protocol/app-daemon/proto")
        .canonicalize()?;

    let proto_files = [
        "wikid/appdaemon/v1/common.proto",
        "wikid/appdaemon/v1/capabilities.proto",
        "wikid/appdaemon/v1/registry.proto",
        "wikid/appdaemon/v1/events.proto",
        "wikid/appdaemon/v1/admission.proto",
        "wikid/appdaemon/v1/service.proto",
    ]
    .map(|relative| proto_root.join(relative));

    let mut includes = vec![proto_root.clone()];
    // Well-known includes: prefer the make target's pinned distribution;
    // fall back to protoc's own include dir for developer convenience.
    if let Ok(pinned) = std::env::var("PROTOC_INCLUDE") {
        let dir = PathBuf::from(pinned);
        if dir.join("google/protobuf/timestamp.proto").exists() {
            includes.push(dir);
        }
    } else if let Some(dir) = protoc_include_dir() {
        includes.push(dir);
    }

    // The schemas live OUTSIDE the crate; declare them so proto edits
    // retrigger codegen.
    println!("cargo:rerun-if-changed={}", proto_root.display());
    for file in &proto_files {
        println!("cargo:rerun-if-changed={}", file.display());
    }

    tonic_prost_build::configure()
        .build_client(true)
        .build_server(true)
        .compile_protos(&proto_files, &includes)?;
    Ok(())
}

/// Locate protoc (PROTOC env, else PATH) and derive its distribution's
/// include directory (…/bin/protoc → …/include).
fn protoc_include_dir() -> Option<PathBuf> {
    let program = std::env::var("PROTOC").unwrap_or_else(|_| "protoc".to_string());
    let resolved = if program.contains('/') {
        let path = PathBuf::from(&program);
        if !path.exists() {
            return None;
        }
        path
    } else {
        let path_env = std::env::var("PATH").ok()?;
        std::env::split_paths(&path_env)
            .map(|dir| dir.join(&program))
            .find(|candidate| candidate.exists())?
    };
    let dir = resolved.parent()?.parent()?.join("include");
    dir.join("google/protobuf/timestamp.proto")
        .is_file()
        .then_some(dir)
}

/// Path type hint for readability of the filter above.
#[allow(dead_code)]
type PathRef<'a> = &'a Path;
