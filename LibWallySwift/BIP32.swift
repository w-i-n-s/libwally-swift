//
//  BIP32.swift
//  BIP32 
//
//  Created by Sjors on 29/05/2019.
//  Copyright © 2019 Blockchain. Distributed under the MIT software
//  license, see the accompanying file LICENSE.md

import Foundation

public struct HDKey {
    var wally_ext_key: ext_key
    public init?(_ seed: BIP39Seed) {
        var bytes_in = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(BIP39_SEED_LEN_512))
        var output: UnsafeMutablePointer<ext_key>?
        defer {
            bytes_in.deallocate()
            if let wally_ext_key = output {
                wally_ext_key.deallocate()
            }
        }
        seed.data.copyBytes(to: bytes_in, count: Int(BIP39_SEED_LEN_512))
        let result = bip32_key_from_seed_alloc(bytes_in, Int(BIP32_ENTROPY_LEN_512), UInt32(BIP32_VER_MAIN_PRIVATE), 0, &output)
        if (result == WALLY_OK) {
            precondition(output != nil)
            self.wally_ext_key = output!.pointee
        } else {
            // From libwally-core docs:
            // The entropy passed in may produce an invalid key. If this happens, WALLY_ERROR will be returned
            // and the caller should retry with new entropy.
            return nil
        }
    }
    
    public var description: String {
        var hdkey = UnsafeMutablePointer<ext_key>.allocate(capacity: 1)
        var output: UnsafeMutablePointer<Int8>?
        defer {
            hdkey.deallocate()
            wally_free_string(output)
        }
        hdkey.initialize(to: self.wally_ext_key)
        
        precondition(bip32_key_to_base58(hdkey, UInt32(BIP32_FLAG_KEY_PRIVATE), &output) == WALLY_OK)
        precondition(output != nil)
        return String(cString: output!)
    }
}
