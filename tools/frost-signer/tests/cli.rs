//! Integration tests for the frost-signer CLI: keygen output shape, signing with
//! each of the three 2-of-3 share pairs (verified against the on-chain FROST
//! verifier), and the single-share refusal.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use frost_secp256k1_evm as frost;

/// A fixed 32-byte message (hex, 0x-prefixed) used across tests.
const MESSAGE_HEX: &str = "0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e";

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!(
            "frost-signer-test-{tag}-{}-{nanos}-{n}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_frost-signer"))
}

fn run_keygen(dir: &Path) {
    let status = Command::new(bin())
        .arg("keygen")
        .arg("--out")
        .arg(dir)
        .status()
        .expect("run keygen");
    assert!(status.success(), "keygen exited non-zero");
}

fn run_sign(dir: &Path, shares: &[&str], message_hex: &str) -> std::process::Output {
    let mut cmd = Command::new(bin());
    cmd.arg("sign").arg("--shares");
    for share in shares {
        cmd.arg(dir.join(share));
    }
    cmd.arg("--message").arg(message_hex);
    cmd.output().expect("run sign")
}

fn load_key_package(path: &Path) -> frost::keys::KeyPackage {
    let raw = fs::read_to_string(path).unwrap();
    let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let hex_str = v["key_package"].as_str().expect("key_package field");
    let bytes = hex::decode(hex_str.trim_start_matches("0x")).unwrap();
    frost::keys::KeyPackage::deserialize(&bytes).expect("valid KeyPackage encoding")
}

#[test]
fn keygen_writes_exactly_four_files_three_shares_and_group_pubkey() {
    let dir = TempDir::new("keygen-files");
    run_keygen(dir.path());

    let mut names: Vec<String> = fs::read_dir(dir.path())
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(
        names,
        vec![
            "group-pubkey.json".to_string(),
            "share-1".to_string(),
            "share-2".to_string(),
            "share-3".to_string(),
        ]
    );
}

#[test]
fn keygen_group_pubkey_file_has_x_and_y_and_nothing_secret() {
    let dir = TempDir::new("keygen-pubkey");
    run_keygen(dir.path());

    let raw = fs::read_to_string(dir.path().join("group-pubkey.json")).unwrap();
    let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let obj = v
        .as_object()
        .expect("group public key file is a JSON object");

    // Exactly {x, y}: no secret scalar or extra field sneaks in.
    let mut keys: Vec<&String> = obj.keys().collect();
    keys.sort();
    assert_eq!(keys, vec!["x", "y"]);

    let x = obj["x"].as_str().expect("x present");
    let y = obj["y"].as_str().expect("y present");
    assert_eq!(
        hex::decode(x.trim_start_matches("0x")).unwrap().len(),
        32,
        "x must be a 32-byte coordinate"
    );
    assert_eq!(
        hex::decode(y.trim_start_matches("0x")).unwrap().len(),
        32,
        "y must be a 32-byte coordinate"
    );
}

/// Sign with the given pair and confirm the on-chain FROST verifier
/// (frost-secp256k1-evm's `VerifyingKey::verify`) accepts the printed signature.
fn assert_pair_signs_and_verifies(a: &str, b: &str) {
    let dir = TempDir::new(&format!("sign-{a}-{b}"));
    run_keygen(dir.path());

    let out = run_sign(dir.path(), &[a, b], MESSAGE_HEX);
    assert!(
        out.status.success(),
        "sign failed for {a}/{b}: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let sig_hex = String::from_utf8(out.stdout).unwrap().trim().to_string();
    assert!(!sig_hex.is_empty(), "sign must print a signature");
    let sig_bytes = hex::decode(sig_hex.trim_start_matches("0x")).expect("signature is hex");
    let signature = frost::Signature::deserialize(&sig_bytes).expect("valid signature encoding");

    let kp = load_key_package(&dir.path().join(a));
    let message = hex::decode(MESSAGE_HEX.trim_start_matches("0x")).unwrap();
    kp.verifying_key()
        .verify(&message, &signature)
        .expect("on-chain verifier accepts the signature");
}

#[test]
fn sign_pair_1_2_produces_signature_the_verifier_accepts() {
    assert_pair_signs_and_verifies("share-1", "share-2");
}

#[test]
fn sign_pair_1_3_produces_signature_the_verifier_accepts() {
    assert_pair_signs_and_verifies("share-1", "share-3");
}

#[test]
fn sign_pair_2_3_produces_signature_the_verifier_accepts() {
    assert_pair_signs_and_verifies("share-2", "share-3");
}

#[test]
fn sign_json_format_commitment_matches_the_signature_the_hex_format_encodes() {
    let dir = TempDir::new("sign-json");
    run_keygen(dir.path());

    let mut cmd = Command::new(bin());
    cmd.arg("sign")
        .arg("--shares")
        .arg(dir.path().join("share-1"))
        .arg(dir.path().join("share-3"))
        .arg("--message")
        .arg(MESSAGE_HEX)
        .arg("--format")
        .arg("json");
    let out = cmd.output().expect("run sign --format json");
    assert!(
        out.status.success(),
        "sign --format json failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let stdout = String::from_utf8(out.stdout).unwrap();
    let v: serde_json::Value =
        serde_json::from_str(stdout.trim()).expect("sign --format json prints JSON");
    let x = hex::decode(v["commitmentX"].as_str().unwrap().trim_start_matches("0x")).unwrap();
    let y = hex::decode(v["commitmentY"].as_str().unwrap().trim_start_matches("0x")).unwrap();
    let z = hex::decode(v["z"].as_str().unwrap().trim_start_matches("0x")).unwrap();
    assert_eq!(x.len(), 32, "commitmentX is a 32-byte word");
    assert_eq!(y.len(), 32, "commitmentY is a 32-byte word");
    assert_eq!(z.len(), 32, "z is a 32-byte word");

    // Reconstruct the compact (compressed-R || z) encoding from the JSON's uncompressed
    // coordinates and confirm it decodes to a signature the on-chain FROST verifier's own
    // math (VerifyingKey::verify) accepts -- proving commitmentX/commitmentY are truly R's
    // coordinates, not just any 32-byte words.
    let prefix: u8 = if y[31] & 1 == 0 { 0x02 } else { 0x03 };
    let mut compact = Vec::with_capacity(65);
    compact.push(prefix);
    compact.extend_from_slice(&x);
    compact.extend_from_slice(&z);
    let signature = frost::Signature::deserialize(&compact).expect("valid signature encoding");

    let kp = load_key_package(&dir.path().join("share-1"));
    let message = hex::decode(MESSAGE_HEX.trim_start_matches("0x")).unwrap();
    kp.verifying_key()
        .verify(&message, &signature)
        .expect("on-chain verifier accepts the reconstructed signature");
}

#[test]
fn sign_with_single_share_exits_nonzero_and_names_threshold() {
    let dir = TempDir::new("single-share");
    run_keygen(dir.path());

    let out = run_sign(dir.path(), &["share-1"], MESSAGE_HEX);
    assert!(
        !out.status.success(),
        "sign with a single share must exit non-zero"
    );
    let stderr = String::from_utf8_lossy(&out.stderr).to_lowercase();
    assert!(
        stderr.contains("threshold"),
        "stderr must name the threshold, got: {stderr}"
    );
}

#[test]
fn a_signature_does_not_verify_against_a_different_message() {
    let dir = TempDir::new("tamper");
    run_keygen(dir.path());

    let out = run_sign(dir.path(), &["share-1", "share-2"], MESSAGE_HEX);
    assert!(out.status.success());
    let sig_hex = String::from_utf8(out.stdout).unwrap().trim().to_string();
    let sig_bytes = hex::decode(sig_hex.trim_start_matches("0x")).unwrap();
    let signature = frost::Signature::deserialize(&sig_bytes).unwrap();

    let kp = load_key_package(&dir.path().join("share-1"));
    // Flip the message's last byte after signing.
    let mut tampered = hex::decode(MESSAGE_HEX.trim_start_matches("0x")).unwrap();
    let last = tampered.len() - 1;
    tampered[last] ^= 0xff;

    assert!(
        kp.verifying_key().verify(&tampered, &signature).is_err(),
        "verifier must reject a signature over a different message"
    );
}

fn run_keygen_with_seed(dir: &Path, seed: &str) {
    let status = Command::new(bin())
        .arg("keygen")
        .arg("--out")
        .arg(dir)
        .arg("--seed")
        .arg(seed)
        .status()
        .expect("run seeded keygen");
    assert!(status.success(), "seeded keygen exited non-zero");
}

fn group_pubkey_x(dir: &Path) -> String {
    let raw = fs::read_to_string(dir.join("group-pubkey.json")).unwrap();
    let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
    v["x"].as_str().expect("group key has x")
    .to_string()
}

#[test]
fn keygen_default_is_deterministic_and_seeded_differs() {
    let d1 = TempDir::new("seed-default-1");
    let d2 = TempDir::new("seed-default-2");
    let d3 = TempDir::new("seed-other");
    run_keygen(d1.path());
    run_keygen(d2.path());
    run_keygen_with_seed(d3.path(), "0x6e6974726f726170");

    let default_x_1 = group_pubkey_x(d1.path());
    let default_x_2 = group_pubkey_x(d2.path());
    let seeded_x = group_pubkey_x(d3.path());

    assert_eq!(default_x_1, default_x_2, "default keygen must be deterministic across runs");
    assert_ne!(default_x_1, seeded_x, "a different --seed must produce a different group key");
}

#[test]
fn keygen_seeded_is_deterministic() {
    let d1 = TempDir::new("seed-det-1");
    let d2 = TempDir::new("seed-det-2");
    run_keygen_with_seed(d1.path(), "0x6e6974726f726170");
    run_keygen_with_seed(d2.path(), "0x6e6974726f726170");
    assert_eq!(
        group_pubkey_x(d1.path()),
        group_pubkey_x(d2.path()),
        "the same --seed must be deterministic"
    );
}
