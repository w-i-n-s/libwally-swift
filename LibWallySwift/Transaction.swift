//
//  Transaction.swift
//  Transaction
//
//  Created by Sjors Provoost on 18/06/2019.
//  Copyright © 2019 Blockchain. Distributed under the MIT software
//  license, see the accompanying file LICENSE.md

import Foundation

public typealias Satoshi = UInt64

public struct TxOutput {
    let wally_tx_output: wally_tx_output
    var amount: Satoshi {
        return self.wally_tx_output.satoshi
    }
    let scriptPubKey: ScriptPubKey

    public init (_ scriptPubKey: ScriptPubKey, _ amount: Satoshi) {
        self.scriptPubKey = scriptPubKey

        var scriptpubkey_bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: scriptPubKey.bytes.count)
        let scriptpubkey_bytes_len = scriptPubKey.bytes.count

        scriptPubKey.bytes.copyBytes(to: scriptpubkey_bytes, count: scriptpubkey_bytes_len)

        var output: UnsafeMutablePointer<wally_tx_output>?
        defer {
            if let wally_tx_output = output {
                wally_tx_output.deallocate()
            }
        }
        precondition(wally_tx_output_init_alloc(amount, scriptpubkey_bytes, scriptpubkey_bytes_len, &output) == WALLY_OK)
        precondition(output != nil)
        self.wally_tx_output = output!.pointee
    }
}

public struct TxInput {
    var wally_tx_input: UnsafeMutablePointer<wally_tx_input>?
    let transaction: Transaction
    public var vout: UInt32 {
        return self.wally_tx_input!.pointee.index
    }
    public var sequence: UInt32 {
        return self.wally_tx_input!.pointee.sequence
    }
    public var scriptSig: ScriptSig

    public var witness: Data? {
        // TODO: obtain from wally_tx_input.witness
        return nil
    }

    public init? (_ tx: Transaction, _ vout: UInt32, _ scriptSig: ScriptSig) {
        if tx.hash == nil {
            return nil
        }

        // We initialize self.wally_tx_input with an empty scriptSig, which is what's used when signing
        // for other inputs. We update it from self.scriptSig as needed during the signing process.
        self.scriptSig = scriptSig

        let sequence: UInt32 = 0xFFFFFFFF
        
        self.transaction = tx

        let tx_hash_bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: tx.hash!.count)
        let tx_hash_bytes_len = tx.hash!.count

        tx.hash!.copyBytes(to: tx_hash_bytes, count: tx_hash_bytes_len)

        precondition(wally_tx_input_init_alloc(tx_hash_bytes, tx_hash_bytes_len, vout, sequence, nil, 0, nil, &self.wally_tx_input) == WALLY_OK)
        precondition(self.wally_tx_input != nil)

    }

    public var signed: Bool {
        return self.scriptSig.signature != nil
    }
}

public struct Transaction {
    var hash: Data? = nil
    
    var wally_tx: UnsafeMutablePointer<wally_tx>?
    
    public var inputs: [TxInput]? = nil
    var outputs: [TxOutput]? = nil

    public init? (_ description: String) {
        if description.count == 64 { // Transaction hash
            if let hash = Data(description) {
                self.hash = Data(hash.reversed())
            } else {
                return nil
            }
        } else { // Transaction hex
            return nil
        }

    }
    
    public init (_ inputs: [TxInput], _ outputs: [TxOutput]) {
        self.inputs = inputs
        self.outputs = outputs
        
        let version: UInt32 = 1
        let lockTime: UInt32 = 0
        
        precondition(wally_tx_init_alloc(version, lockTime, inputs.count, outputs.count, &self.wally_tx) == WALLY_OK)
        precondition(self.wally_tx != nil)
        
        for input in inputs {
            self.addInput(input)
        }
        
        for output in outputs {
            self.addOutput(output)
        }
    }
    
    public var description: String? {
        if (self.wally_tx == nil) {
            return nil
        }
        precondition(self.inputs != nil)
        for input in self.inputs! {
            if !input.signed {
                return nil
            }
        }
        var output: UnsafeMutablePointer<Int8>?
        defer {
            wally_free_string(output)
        }
        
        precondition(wally_tx_to_hex(self.wally_tx, UInt32(WALLY_TX_FLAG_USE_WITNESS), &output) == WALLY_OK)
        precondition(output != nil)
        return String(cString: output!)
    }
    
    mutating func addInput (_ input: TxInput) {
        precondition(wally_tx_add_input(self.wally_tx, input.wally_tx_input) == WALLY_OK)
    }
    
    mutating func addOutput (_ output: TxOutput) {
        let tx_output = UnsafeMutablePointer<wally_tx_output>.allocate(capacity: 1)
        defer {
            tx_output.deallocate()
        }
        tx_output.pointee = output.wally_tx_output
        
        precondition(wally_tx_add_output(self.wally_tx, tx_output) == WALLY_OK)
    }
    
    var totalOut: Satoshi? {
        if (self.wally_tx == nil) {
            return nil
        }
        var value_out = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        defer {
            value_out.deallocate()
        }
        
        precondition(wally_tx_get_total_output_satoshi(self.wally_tx, value_out) == WALLY_OK)
        
        return value_out.pointee;
    }
    
    var vbytes: Int? {
        if (self.wally_tx == nil) {
            return nil
        }
        
        precondition(self.inputs != nil)

        // Set scriptSig for all unsigned inputs to .feeWorstCase
        for (index, input) in self.inputs!.enumerated() {
            if (!input.signed) {
                let scriptSig = input.scriptSig.render(.feeWorstCase)!
                let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: scriptSig.count)
                let bytes_len = scriptSig.count
                scriptSig.copyBytes(to: bytes, count: bytes_len)
                
                precondition(wally_tx_set_input_script(self.wally_tx, index, bytes, bytes_len) == WALLY_OK)
            }
        }
        
        var value_out = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        defer {
            value_out.deallocate()
        }
        
        precondition(wally_tx_get_vsize(self.wally_tx, value_out) == WALLY_OK)
        
        return value_out.pointee;
    }
    
    public mutating func sign (_ privKeys: [HDKey]) -> Bool {
        if self.wally_tx == nil {
            return false
        }
        precondition(self.inputs != nil)
        if privKeys.count != self.inputs!.count {
            return false
        }
        
        // Loop through inputs to sign:
        for (i, _) in self.inputs!.enumerated() {
            // Prep input for signing:
            let scriptSig = self.inputs![i].scriptSig.render(.signThisInput)!
            let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: scriptSig.count)
            let bytes_len = scriptSig.count
            scriptSig.copyBytes(to: bytes, count: bytes_len)
            
            var message_bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(SHA256_LEN))
            defer {
                message_bytes.deallocate()
            }

            // Create hash for signing
            precondition(wally_tx_get_btc_signature_hash(self.wally_tx, i, bytes, bytes_len, 0, UInt32(WALLY_SIGHASH_ALL), 0, message_bytes, Int(SHA256_LEN)) == WALLY_OK)
            
            var compact_sig_bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(EC_SIGNATURE_LEN))
            defer {
                compact_sig_bytes.deallocate()
            }
            
            // Sign hash using private key (without 0 prefix)
            precondition(EC_MESSAGE_HASH_LEN == SHA256_LEN)
            
            var tmp = privKeys[i].wally_ext_key.priv_key
            let privKey = [UInt8](UnsafeBufferPointer(start: &tmp.1, count: Int(EC_PRIVATE_KEY_LEN)))
            // Ensure private key is valid
            precondition(wally_ec_private_key_verify(privKey, Int(EC_PRIVATE_KEY_LEN)) == WALLY_OK)
        
            precondition(wally_ec_sig_from_bytes(privKey, Int(EC_PRIVATE_KEY_LEN), message_bytes, Int(EC_MESSAGE_HASH_LEN), UInt32(EC_FLAG_ECDSA | EC_FLAG_GRIND_R), compact_sig_bytes, Int(EC_SIGNATURE_LEN)) == WALLY_OK)
            
            // Convert to low s form:
            let sig_norm_bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(EC_SIGNATURE_LEN))
            defer {
                sig_norm_bytes.deallocate()
            }
            precondition(wally_ec_sig_normalize(compact_sig_bytes, Int(EC_SIGNATURE_LEN), sig_norm_bytes, Int(EC_SIGNATURE_LEN)) == WALLY_OK)
            
            // Convert normalized signature to DER
            let sig_bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(EC_SIGNATURE_DER_MAX_LEN))
            var sig_bytes_written = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            defer {
                sig_bytes.deallocate()
                sig_bytes_written.deallocate()
            }
            precondition(wally_ec_sig_to_der(sig_norm_bytes, Int(EC_SIGNATURE_LEN), sig_bytes, Int(EC_SIGNATURE_DER_MAX_LEN), sig_bytes_written) == WALLY_OK)
            
            // Store signature in TxInput
            self.inputs![i].scriptSig.signature = Data(bytes: sig_bytes, count: sig_bytes_written.pointee)
            
            // Update scriptSig:
            let signedScriptSig = self.inputs![i].scriptSig.render(.signed)!
            let bytes_signed_scriptsig = UnsafeMutablePointer<UInt8>.allocate(capacity: signedScriptSig.count)
            let bytes_signed_scriptsig_len = signedScriptSig.count
            signedScriptSig.copyBytes(to: bytes_signed_scriptsig, count: bytes_signed_scriptsig_len)
            
            precondition(wally_tx_set_input_script(self.wally_tx, i, bytes_signed_scriptsig, bytes_signed_scriptsig_len) == WALLY_OK)
        }

        return true
    }

}
