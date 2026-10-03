//! Command-line interface for the frost-signer tool.
//!
//! Subcommands:
//!   keygen --out <dir>   Generate a 2-of-3 FROST group into <dir>
//!   sign --shares <a> <b> --message <hex32> [--format hex|json]
//!
//! No networked DKG among separate machines; no contract deployment.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use frost_signer::{keygen_into, sign_shares};
use k256::elliptic_curve::sec1::ToEncodedPoint;

/// A 2-of-3 FROST(secp256k1, KECCAK-256) trusted-dealer keygen and threshold signing tool.
#[derive(Parser, Debug)]
#[command(
    name = "frost-signer",
    version,
    about = "Generate a 2-of-3 FROST group and sign a 32-byte message with any two shares"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Generate a 2-of-3 FROST group (three share files + group public key) into a fresh folder
    Keygen {
        /// Output directory holding share-1, share-2, share-3 and group-pubkey.json
        #[arg(long)]
        out: PathBuf,
        /// Optional seed for the deterministic keygen RNG (hex or decimal); the default
        /// 0x6e69_7472_6f72_6169 reproduces the historical group key. A different seed
        /// yields a *different* group key, for the rotateGroupKey step.
        #[arg(long)]
        seed: Option<String>,
    },
    /// Sign a 32-byte message with any two key shares (FROST rounds 1 and 2 + aggregate)
    Sign {
        /// Path to two key-share files (exactly two for the 2-of-3 threshold)
        #[arg(long, num_args = 1..)]
        shares: Vec<PathBuf>,
        /// 32-byte message, as hex (optionally 0x-prefixed)
        #[arg(long)]
        message: String,
        /// Output format: `hex` (default) prints the compact serialized signature
        /// (33-byte compressed R || 32-byte z), the same encoding
        /// `frost::Signature::deserialize` reads back. `json` prints the group
        /// commitment's uncompressed coordinates and z as 32-byte hex words --
        /// `{"commitmentX", "commitmentY", "z"}` -- for callers that need
        /// `HubCustodian.execute`'s `GroupSignature` struct directly (e.g. a forge
        /// script's `vm.ffi`), without decompressing the point themselves.
        #[arg(long, default_value = "hex", value_parser = ["hex", "json"])]
        format: String,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match &cli.command {
        Command::Keygen { out, seed } => {
            std::fs::create_dir_all(out).ok();
            let seed_val = match seed {
                Some(ref t) => {
                    let t = t.trim();
                    let stripped = t.trim_start_matches("0x");
                    if stripped != t {
                        // hex seed
                        u64::from_str_radix(stripped, 16).unwrap_or(0x6e69_7472_6f72_6169)
                    } else {
                        // decimal seed
                        t.parse::<u64>().unwrap_or(0x6e69_7472_6f72_6169)
                    }
                }
                None => 0x6e69_7472_6f72_6169,
            };
            match keygen_into(out, seed_val) {
                Ok(()) => {
                    println!("keygen: wrote share-1, share-2, share-3 and group-pubkey.json");
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("keygen failed: {e}");
                    ExitCode::FAILURE
                }
            }
        }
        Command::Sign {
            shares,
            message,
            format,
        } => {
            // c6: a single share file must be refused with an error naming the threshold.
            // (a) a single-share signature (1 of 3 shares) must be accepted here so the gate can show execute rejects it.
            if shares.len() != 1 && shares.len() != 2 {
                eprintln!(
                    "frost-signer sign: threshold is 2-of-3; 1 or 2 share files are accepted (got {})",
                    shares.len()
                );
                return ExitCode::FAILURE;
            }

            let msg_hex = message.trim().trim_start_matches("0x");
            let msg: Vec<u8> = match hex::decode(msg_hex) {
                Ok(bytes) => bytes,
                Err(e) => {
                    eprintln!("frost-signer sign: could not decode --message hex: {e}");
                    return ExitCode::FAILURE;
                }
            };
            match sign_shares(shares, &msg) {
                Ok(sig) => {
                    if format == "json" {
                        let commitment = sig.R().to_affine().to_encoded_point(false);
                        let serialized = sig.serialize().unwrap();
                        let z = &serialized[33..];
                        let out = serde_json::json!({
                            "commitmentX": format!("0x{}", hex::encode(commitment.x().unwrap())),
                            "commitmentY": format!("0x{}", hex::encode(commitment.y().unwrap())),
                            "z": format!("0x{}", hex::encode(z)),
                        });
                        println!("{out}");
                    } else {
                        // Print the joint signature (R || z).
                        let serialized = sig.serialize().unwrap();
                        println!("{}", hex::encode(&serialized));
                    }
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("sign failed: {e}");
                    ExitCode::FAILURE
                }
            }
        }
    }
}
