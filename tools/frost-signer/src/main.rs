//! Command-line interface for the frost-signer tool.
//!
//! Subcommands:
//!   keygen --out <dir>   Generate a 2-of-3 FROST group into <dir>
//!   sign --shares <a> <b> --message <hex32>
//!
//! No networked DKG among separate machines; no contract deployment.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use frost_signer::{keygen_into, sign_shares};
use hex;

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
    },
    /// Sign a 32-byte message with any two key shares (FROST rounds 1 and 2 + aggregate)
    Sign {
        /// Path to two key-share files (exactly two for the 2-of-3 threshold)
        #[arg(long, num_args = 1..)]
        shares: Vec<PathBuf>,
        /// 32-byte message, as hex (optionally 0x-prefixed)
        #[arg(long)]
        message: String,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match &cli.command {
        Command::Keygen { out } => {
            std::fs::create_dir_all(out).ok();
            match keygen_into(out) {
                Ok(()) => {
                    println!("keygen: wrote share-1, share-2, share-3 and group-pubkey.json");
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("keygen failed: {}", e);
                    ExitCode::FAILURE
                }
            }
        }
        Command::Sign { shares, message } => {
            // c6: a single share file must be refused with an error naming the threshold.
            if shares.len() != 2 {
                eprintln!(
                    "frost-signer sign: threshold is 2-of-3; exactly 2 share files are required (got {})",
                    shares.len()
                );
                return ExitCode::FAILURE;
            }

            let msg_hex = message.trim().trim_start_matches("0x");
            let msg: Vec<u8> = match hex::decode(msg_hex) {
                Ok(bytes) => bytes,
                Err(e) => {
                    eprintln!("frost-signer sign: could not decode --message hex: {}", e);
                    return ExitCode::FAILURE;
                }
            };
            match sign_shares(shares, &msg) {
                Ok(sig) => {
                    let serialized = sig.serialize().unwrap();
                    // Print the joint signature (R || z).
                    println!("{}", hex::encode(&serialized));
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("sign failed: {}", e);
                    ExitCode::FAILURE
                }
            }
        }
    }
}
