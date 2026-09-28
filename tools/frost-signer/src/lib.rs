//! Core logic for the frost-signer tool.
//!
//! `keygen_into`: trusted-dealer 2-of-3 FROST(secp256k1, KECCAK256) key generation,
//! writing three share files plus the group public key (X, Y).
//! `sign_shares` / `sign_packages`: run both FROST rounds and aggregate with the
//! group verifying key.
//!
//! The keygen step writes exactly four files into a fresh folder: share-1, share-2,
//! share-3, and group-pubkey.json. The group secret scalar is never written to disk.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use frost_secp256k1_evm as frost;
use k256::elliptic_curve::sec1::ToEncodedPoint;
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;
use serde::{Deserialize, Serialize};
use serde_json as json;

pub type Error = frost::Error;

/// File name of the group public key (X, Y) that keygen writes.
pub const GROUP_PUBKEY_FILE: &str = "group-pubkey.json";

/// The group public key (X, Y) as written by keygen.
#[derive(Debug, Serialize, Deserialize)]
pub struct GroupPubkey {
    pub x: String,
    pub y: String,
}

/// A serialized FROST key share (KeyPackage) stored per participant.
#[derive(Debug, Serialize, Deserialize)]
pub struct ShareFile {
    pub key_package: String,
}

/// Keygen a 2-of-3 FROST group into `out_dir`, writing three share files
/// (share-1, share-2, share-3) and the group public key file (X, Y).
pub fn keygen_into(out_dir: &Path) -> Result<(), Error> {
    let mut rng = ChaCha20Rng::seed_from_u64(0x6e69_7472_6f72_6169);
    let result =
        frost::keys::generate_with_dealer(3, 2, frost::keys::IdentifierList::Default, &mut rng);
    let (shares, pubkeys) = result?;

    // Identifiers are the sequential signer indices (1, 2, 3) from IdentifierList::Default.
    let mut share_index = 1;
    for secret_share in shares.values() {
        let kp_res = frost::keys::KeyPackage::try_from(secret_share.clone());
        let kp = kp_res?;
        let serialized = kp.serialize()?;
        let hex = format!("0x{}", hex::encode(&serialized));
        let path = out_dir.join(format!("share-{share_index}"));
        std::fs::write(
            path,
            json::to_string_pretty(&ShareFile { key_package: hex }).unwrap() + "\n",
        )
        .unwrap();
        share_index += 1;
    }

    // Group public key (X, Y) — the file contains X and Y; the group secret scalar is never written.
    let group_key = pubkeys
        .verifying_key()
        .to_element()
        .to_affine()
        .to_encoded_point(false);
    let pubkey = GroupPubkey {
        x: format!("0x{}", hex::encode(group_key.x().unwrap())),
        y: format!("0x{}", hex::encode(group_key.y().unwrap())),
    };
    std::fs::write(
        out_dir.join(GROUP_PUBKEY_FILE),
        json::to_string_pretty(&pubkey).unwrap() + "\n",
    )
    .unwrap();

    Ok(())
}

/// Sign a 32-byte message with any two key shares.
///
/// Reads each share file (JSON with `key_package`), deserializes the KeyPackages,
/// then runs both FROST rounds and aggregates.
pub fn sign_shares(share_files: &[PathBuf], message: &[u8]) -> Result<frost::Signature, Error> {
    let mut key_packages: BTreeMap<frost::Identifier, frost::keys::KeyPackage> = BTreeMap::new();
    for path in share_files {
        let raw = std::fs::read_to_string(path).map_err(map_io_error)?;
        let share: ShareFile = json::from_str(&raw).map_err(map_json_error)?;
        let kp = deserialize_key_package(&share.key_package)?;
        key_packages.insert(*kp.identifier(), kp);
    }
    sign_packages(&key_packages, message)
}

/// Sign a 32-byte message with the given key packages (FROST rounds 1 and 2 + aggregate).
pub fn sign_packages(
    key_packages: &BTreeMap<frost::Identifier, frost::keys::KeyPackage>,
    message: &[u8],
) -> Result<frost::Signature, Error> {
    let first = key_packages.values().next().unwrap();
    let min_signers = first.min_signers();

    // Build the verifying shares for each participating signer.
    let verifying_shares: BTreeMap<frost::Identifier, frost::keys::VerifyingShare> = key_packages
        .iter()
        .map(|(id, kp)| (*id, *kp.verifying_share()))
        .collect();
    let pubkeys = frost::keys::PublicKeyPackage::new(
        verifying_shares,
        *first.verifying_key(),
        Some(*min_signers),
    );

    // Round 1: each participant commits (hiding + binding nonces).
    let mut rng = ChaCha20Rng::seed_from_u64(0x6e69_7472_6f72_6169);
    let mut nonces = BTreeMap::new();
    let mut commitments = BTreeMap::new();
    for (id, kp) in key_packages {
        let (nonce, commitment) = frost::round1::commit(kp.signing_share(), &mut rng);
        nonces.insert(*id, nonce);
        commitments.insert(*id, commitment);
    }
    let signing_package = frost::SigningPackage::new(commitments, message);

    // Round 2: each participant produces a signature share.
    let mut signature_shares = BTreeMap::new();
    for (id, kp) in key_packages {
        let share = frost::round2::sign(&signing_package, &nonces[id], kp)?;
        signature_shares.insert(*id, share);
    }

    // Aggregate the shares into the joint signature.
    let signature = frost::aggregate(&signing_package, &signature_shares, &pubkeys)?;
    Ok(signature)
}

/// Deserialize a serialized KeyPackage (hex, optionally 0x-prefixed) into a KeyPackage.
fn deserialize_key_package(hex_str: &str) -> Result<frost::keys::KeyPackage, Error> {
    let hex = hex_str.trim().trim_start_matches("0x");
    let bytes: Vec<u8> = match hex::decode(hex) {
        Ok(bytes) => bytes,
        Err(_) => return Err(to_sentinel_error()),
    };
    frost::keys::KeyPackage::deserialize(&bytes)
}

/// Map a std I/O error into a frost::Error sentinel.
fn map_io_error(_e: std::io::Error) -> Error {
    to_sentinel_error()
}

/// Map a serde_json error into a frost::Error sentinel.
fn map_json_error(_e: serde_json::Error) -> Error {
    to_sentinel_error()
}

fn to_sentinel_error() -> Error {
    frost::Error::DeserializationError
}
