#!/usr/bin/env swift
// Signs a release file for the in-app updater (spec 11.3): writes <file>.sig, the base64
// Ed25519 signature made with the base64 private key in UPDATE_SIGNING_KEY.
//   UPDATE_SIGNING_KEY=… Scripts/sign-update.swift dist/V2Mac-1.2.3.dmg
//   Scripts/sign-update.swift keygen <private key file>   (prints the public key for AppInstaller.updateKey)
import CryptoKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

if args.first == "keygen" {
    guard args.count == 2 else { fail("usage: sign-update.swift keygen <private key file>") }
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: args[1], contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("cannot write \(args[1])") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}

guard args.count == 1 else { fail("usage: UPDATE_SIGNING_KEY=<base64> sign-update.swift <file>") }
guard let secret = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"].flatMap({ Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret) else { fail("UPDATE_SIGNING_KEY is missing or not a base64 Ed25519 key") }
let signature = try key.signature(for: Data(contentsOf: URL(fileURLWithPath: args[0])))
try (signature.base64EncodedString() + "\n").write(toFile: args[0] + ".sig", atomically: true, encoding: .utf8)
print("Signed \(args[0])")
