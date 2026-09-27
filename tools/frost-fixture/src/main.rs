//! Signs one HubCustodian operation with a 2-of-3 FROST(secp256k1, KECCAK-256) group and writes
//! the group key, message and signature to `test/fixtures/frost-2of3.json`.
//!
//! The operation hash is computed here independently of Solidity, for the fixed custodian address,
//! chain and call that `HubCustodianTest.test_execute_acceptsThresholdSignatureFromFrostCrate`
//! deploys and submits.
//!
//! Run from the repository root: `cargo run --manifest-path tools/frost-fixture/Cargo.toml`

use std::collections::BTreeMap;

use frost_secp256k1_evm as frost;
use k256::elliptic_curve::sec1::ToEncodedPoint;
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;
use sha3::{Digest, Keccak256};

const CHAIN_ID: u64 = 31337;
const CUSTODIAN: [u8; 20] = address(0xC057_0D1A);
const TARGET: [u8; 20] = address(0x7A26_E700);
/// `Target.hit()`
const CALLDATA: [u8; 4] = [0x2a, 0xe3, 0x59, 0x4a];
const OPERATION_TYPE: &str = "HubCustodian.Operation(uint256 chainId,address custodian,uint256 nonce,address target,uint256 value,bytes32 dataHash)";

const fn address(low: u32) -> [u8; 20] {
    let mut a = [0u8; 20];
    let b = low.to_be_bytes();
    a[16] = b[0];
    a[17] = b[1];
    a[18] = b[2];
    a[19] = b[3];
    a
}

fn keccak(data: &[u8]) -> [u8; 32] {
    Keccak256::digest(data).into()
}

fn word_u64(v: u64) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[24..].copy_from_slice(&v.to_be_bytes());
    w
}

fn word_address(a: [u8; 20]) -> [u8; 32] {
    let mut w = [0u8; 32];
    w[12..].copy_from_slice(&a);
    w
}

/// keccak256(abi.encode(OPERATION_TYPEHASH, chainId, custodian, nonce, target, value, keccak256(data)))
fn operation_hash(nonce: u64) -> [u8; 32] {
    let mut encoded = Vec::with_capacity(7 * 32);
    encoded.extend_from_slice(&keccak(OPERATION_TYPE.as_bytes()));
    encoded.extend_from_slice(&word_u64(CHAIN_ID));
    encoded.extend_from_slice(&word_address(CUSTODIAN));
    encoded.extend_from_slice(&word_u64(nonce));
    encoded.extend_from_slice(&word_address(TARGET));
    encoded.extend_from_slice(&word_u64(0));
    encoded.extend_from_slice(&keccak(&CALLDATA));
    keccak(&encoded)
}

fn hex_word(bytes: &[u8]) -> String {
    format!("0x{}", hex::encode(bytes))
}

fn main() -> Result<(), frost::Error> {
    let mut rng = ChaCha20Rng::seed_from_u64(0x6e69_7472_6f72_6169);
    let (shares, public_key_package) =
        frost::keys::generate_with_dealer(3, 2, frost::keys::IdentifierList::Default, &mut rng)?;
    let key_packages: BTreeMap<_, _> = shares
        .into_iter()
        .map(|(id, share)| Ok((id, frost::keys::KeyPackage::try_from(share)?)))
        .collect::<Result<_, frost::Error>>()?;

    let message = operation_hash(0);
    let signers: Vec<frost::Identifier> = vec![1u16.try_into()?, 3u16.try_into()?];

    let mut nonces = BTreeMap::new();
    let mut commitments = BTreeMap::new();
    for id in &signers {
        let (n, c) = frost::round1::commit(key_packages[id].signing_share(), &mut rng);
        nonces.insert(*id, n);
        commitments.insert(*id, c);
    }
    let signing_package = frost::SigningPackage::new(commitments, &message);
    let mut shares = BTreeMap::new();
    for id in &signers {
        shares.insert(
            *id,
            frost::round2::sign(&signing_package, &nonces[id], &key_packages[id])?,
        );
    }
    let signature = frost::aggregate(&signing_package, &shares, &public_key_package)?;
    public_key_package
        .verifying_key()
        .verify(&message, &signature)?;

    let group_key = public_key_package
        .verifying_key()
        .to_element()
        .to_affine()
        .to_encoded_point(false);
    let commitment = signature.R().to_affine().to_encoded_point(false);
    // Serialized as R (33-byte compressed point) || z (32 bytes).
    let serialized = signature.serialize()?;
    let z = &serialized[33..];

    let fixture = serde_json::json!({
        "threshold": "2-of-3",
        "signers": [1, 3],
        "chainId": CHAIN_ID,
        "custodian": hex_word(&CUSTODIAN),
        "target": hex_word(&TARGET),
        "nonce": 0,
        "operationHash": hex_word(&message),
        "groupKeyX": hex_word(group_key.x().unwrap()),
        "groupKeyY": hex_word(group_key.y().unwrap()),
        "commitmentX": hex_word(commitment.x().unwrap()),
        "commitmentY": hex_word(commitment.y().unwrap()),
        "z": hex_word(z),
    });
    let path = "test/fixtures/frost-2of3.json";
    std::fs::write(path, serde_json::to_string_pretty(&fixture).unwrap() + "\n").unwrap();
    println!("wrote {path}");
    Ok(())
}
