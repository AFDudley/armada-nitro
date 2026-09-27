//! Generates the JSON fixture consumed by test/FrostSigner.t.sol: keygens a fresh
//! 2-of-3 group with frost-signer's own logic, signs a fixed 32-byte message with
//! each of the three share pairs, and writes the group key + per-pair (R, z) so the
//! forge tests can call the same `FROST.verifySignature` that HubCustodian uses.
//!
//! Not part of the frost-signer CLI surface (no `--help` entry): run with
//! `cargo run --manifest-path tools/frost-signer/Cargo.toml --example gen_forge_fixture -- <out.json>`.

use k256::elliptic_curve::sec1::ToEncodedPoint;

/// Fixed 32-byte message signed for the fixture; the forge tamper test flips its last byte.
const MESSAGE: [u8; 32] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
    26, 27, 28, 29, 30, 31,
];

fn hex_word(bytes: &[u8]) -> String {
    format!("0x{}", hex::encode(bytes))
}

fn main() {
    let out_path = std::env::args()
        .nth(1)
        .expect("usage: gen_forge_fixture <out.json>");

    let dir = std::env::temp_dir().join(format!(
        "frost-signer-fixture-src-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    frost_signer::keygen_into(&dir).expect("keygen");

    let pubkey_raw = std::fs::read_to_string(dir.join(frost_signer::GROUP_PUBKEY_FILE)).unwrap();
    let pubkey: frost_signer::GroupPubkey = serde_json::from_str(&pubkey_raw).unwrap();

    let pairs: [(&str, &str, &str); 3] = [
        ("share-1", "share-2", "pair12"),
        ("share-1", "share-3", "pair13"),
        ("share-2", "share-3", "pair23"),
    ];

    let mut sigs = serde_json::Map::new();
    for (a, b, key) in pairs {
        let paths = vec![dir.join(a), dir.join(b)];
        let signature = frost_signer::sign_shares(&paths, &MESSAGE).expect("sign");
        let commitment = signature.R().to_affine().to_encoded_point(false);
        let serialized = signature.serialize().expect("serialize signature");
        let z = &serialized[33..];
        sigs.insert(
            key.to_string(),
            serde_json::json!({
                "commitmentX": hex_word(commitment.x().unwrap()),
                "commitmentY": hex_word(commitment.y().unwrap()),
                "z": hex_word(z),
            }),
        );
    }

    let fixture = serde_json::json!({
        "groupKeyX": pubkey.x,
        "groupKeyY": pubkey.y,
        "message": hex_word(&MESSAGE),
        "signatures": sigs,
    });

    std::fs::write(
        &out_path,
        serde_json::to_string_pretty(&fixture).unwrap() + "\n",
    )
    .unwrap();
    std::fs::remove_dir_all(&dir).ok();
    println!("wrote {out_path}");
}
