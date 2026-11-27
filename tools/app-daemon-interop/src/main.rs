//! The app–daemon interop peer. See crate docs (Cargo.toml): `serve` is the
//! fixture server the Swift tests drive the production client against;
//! `probe` validates the production Swift server from a non-Swift client.
//! Not a shipping product; Rust protocol conformance proves the CONTRACT,
//! not Rust daemon packaging, App Group access, Keychain access, or Apple
//! framework parity.

mod corpus;
mod fixture_server;
mod probe;

use std::path::PathBuf;

/// Generated bindings — built at crate build time from
/// Protocol/app-daemon/proto (the same schemas the Swift side compiles).
pub mod proto {
    tonic::include_proto!("wikid.appdaemon.v1");
}

#[derive(Debug, Clone)]
struct Args {
    mode: Mode,
    socket: PathBuf,
    corpus_path: PathBuf,
    case: Option<String>,
    serve_error: Option<String>,
    expect_error: Option<String>,
    incompatible: bool,
    oversize_response: bool,
    expect_oversize: bool,
    expect_incompatible: bool,
}

#[derive(Debug, Clone, PartialEq)]
enum Mode {
    Serve,
    Probe,
}

fn usage() -> String {
    "usage:\n  \
     app-daemon-interop serve  --socket <path> --corpus <path> [--case <id>] \
     [--serve-error <case-id>] [--incompatible] [--oversize-response]\n  \
     app-daemon-interop probe  --socket <path> --corpus <path> [--case <id>] \
     [--expect-error <case-id>] [--expect-oversize] [--expect-incompatible]"
        .to_string()
}

fn parse_args() -> Result<Args, String> {
    let mut mode: Option<Mode> = None;
    let mut socket = None;
    let mut corpus_path = None;
    let mut case = None;
    let mut serve_error = None;
    let mut expect_error = None;
    let mut incompatible = false;
    let mut oversize_response = false;
    let mut expect_oversize = false;
    let mut expect_incompatible = false;

    let mut iter = std::env::args().skip(1);
    while let Some(flag) = iter.next() {
        match flag.as_str() {
            "serve" => mode = Some(Mode::Serve),
            "probe" => mode = Some(Mode::Probe),
            "--socket" => socket = Some(PathBuf::from(next(&mut iter)?)),
            "--corpus" => corpus_path = Some(PathBuf::from(next(&mut iter)?)),
            "--case" => case = Some(next(&mut iter)?),
            "--serve-error" => serve_error = Some(next(&mut iter)?),
            "--expect-error" => expect_error = Some(next(&mut iter)?),
            "--incompatible" => incompatible = true,
            "--oversize-response" => oversize_response = true,
            "--expect-oversize" => expect_oversize = true,
            "--expect-incompatible" => expect_incompatible = true,
            other => return Err(format!("unknown argument '{other}'\n{}", usage())),
        }
    }
    Ok(Args {
        mode: mode.ok_or_else(|| format!("mode missing\n{}", usage()))?,
        socket: socket.ok_or_else(|| format!("--socket missing\n{}", usage()))?,
        corpus_path: corpus_path.ok_or_else(|| format!("--corpus missing\n{}", usage()))?,
        case,
        serve_error,
        expect_error,
        incompatible,
        oversize_response,
        expect_oversize,
        expect_incompatible,
    })
}

fn next(iter: &mut impl Iterator<Item = String>) -> Result<String, String> {
    iter.next().ok_or_else(|| format!("flag value missing\n{}", usage()))
}

#[tokio::main]
async fn main() {
    let args = match parse_args() {
        Ok(args) => args,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(2);
        }
    };
    let result = match args.mode {
        Mode::Serve => {
            let corpus = corpus::load(&args.corpus_path);
            match corpus {
                Ok(corpus) => {
                    let options = fixture_server::ServeOptions {
                        case: args.case.clone(),
                        serve_error: args.serve_error.clone(),
                        incompatible: args.incompatible,
                        oversize_response: args.oversize_response,
                    };
                    let server = fixture_server::FixtureServer::options(&options, corpus);
                    fixture_server::serve(args.socket.clone(), server).await
                }
                Err(message) => Err(message),
            }
        }
        Mode::Probe => {
            let probe_args = probe::ProbeArgs {
                socket: args.socket.clone(),
                corpus_path: args.corpus_path.clone(),
                list_case: args.case.clone().unwrap_or_else(|| "list-wikis-basic".into()),
                expect_error: args.expect_error.clone(),
                expect_oversize: args.expect_oversize,
                expect_incompatible: args.expect_incompatible,
            };
            probe::run(probe_args).await
        }
    };
    if let Err(message) = result {
        eprintln!("app-daemon-interop: {message}");
        std::process::exit(1);
    }
    println!("app-daemon-interop: ok (mode={:?})", args.mode);
}
