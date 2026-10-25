#!/usr/bin/env python3
"""Generates test/fixtures/wallet_vectors.json from Bitcoin Core (test-only).

Runs an OFFLINE regtest bitcoind (temp datadir, no peers, no DNS), creates a
fresh disposable descriptor wallet, and exports PUBLIC data only:
descriptors + checksums (getdescriptorinfo), derived scriptPubKeys
(deriveaddresses + validateaddress), and a small chain: funding, a spend with
change, a coinbase to the wallet, with raw txs, headers, block hashes and
merkle proofs computed from Core's block data. The wallet (and its private
keys) is deleted afterwards and never written anywhere else.

Usage: python3 -I tool/regtest/generate_test_fixtures.py [BITCOIND] [OUT]
"""
import base64
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

BITCOIND = sys.argv[1] if len(sys.argv) > 1 else shutil.which("bitcoind")
OUT = sys.argv[2] if len(sys.argv) > 2 else "test/fixtures/wallet_vectors.json"
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


class Core:
    def __init__(self, chain):
        self.dir = tempfile.mkdtemp(prefix="fixturegen_")
        self.port = free_port()
        self.proc = subprocess.Popen([BITCOIND, f"-chain={chain}", f"-datadir={self.dir}", "-listen=0", "-connect=0",
            "-dnsseed=0", "-fixedseeds=0", f"-rpcport={self.port}", "-rpcuser=u", "-rpcpassword=p",
            "-rpcbind=127.0.0.1", "-rpcallowip=127.0.0.1", "-fallbackfee=0.0002", "-txindex=1", "-printtoconsole=0"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                self("getblockcount"); return
            except Exception:
                time.sleep(0.2)
        raise RuntimeError("bitcoind did not start")

    def __call__(self, method, *params, wallet=None):
        url = f"http://127.0.0.1:{self.port}/" + (f"wallet/{wallet}" if wallet else "")
        req = urllib.request.Request(url, data=json.dumps({"jsonrpc": "1.0", "id": 1, "method": method, "params": list(params)}).encode())
        req.add_header("Authorization", "Basic " + base64.b64encode(b"u:p").decode())
        try:
            with urllib.request.urlopen(req, timeout=60) as r: d = json.loads(r.read())
        except urllib.error.HTTPError as e: d = json.loads(e.read())
        if d.get("error"): raise RuntimeError(f"{method}: {d['error']}")
        return d["result"]

    def close(self):
        try: self("stop")
        except Exception: pass
        try: self.proc.wait(30)
        except subprocess.TimeoutExpired: self.proc.kill()
        shutil.rmtree(self.dir, ignore_errors=True)


def dsha(b): return hashlib.sha256(hashlib.sha256(b).digest()).digest()


def merkle_proof(txids, index):
    """Electrum-style proof: sibling hashes (display hex), leaf level first."""
    level = [bytes.fromhex(t)[::-1] for t in txids]
    siblings, pos = [], index
    while len(level) > 1:
        if len(level) % 2: level.append(level[-1])
        siblings.append(level[pos ^ 1][::-1].hex())
        level = [dsha(level[i] + level[i + 1]) for i in range(0, len(level), 2)]
        pos //= 2
    return siblings


def b58check_decode(s):
    n = 0
    for ch in s: n = n * 58 + B58.index(ch)
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
    payload, chk = raw[:-4], raw[-4:]
    assert dsha(payload)[:4] == chk
    return payload


def b58check_encode(payload):
    data = payload + dsha(payload)[:4]
    n = int.from_bytes(data, "big"); out = ""
    while n: n, r = divmod(n, 58); out = B58[r] + out
    return out


def main():
    core = Core("regtest")
    try:
        core("createwallet", "subject"); core("createwallet", "miner")
        descs = {}
        for d in core("listdescriptors", wallet="subject")["descriptors"]:
            kind = {"pkh": "pkh", "sh": "sh_wpkh", "wpkh": "wpkh", "tr": "tr"}[d["desc"].split("(")[0]]
            descs[(kind, d["internal"])] = d["desc"]
        vectors = {"generator": "Bitcoin Core " + core("getnetworkinfo")["subversion"], "types": {}}
        for kind in ("pkh", "sh_wpkh", "wpkh", "tr"):
            ext, internal = descs[(kind, False)], descs[(kind, True)]
            body = ext.split("#")[0]
            multipath = core("getdescriptorinfo", body.replace("/0/*)", "/<0;1>/*)"))["descriptor"]
            entry = {"external": ext, "internal": internal, "multipath": multipath, "scripts": {}}
            for branch, desc in (("external", ext), ("internal", internal)):
                addrs = core("deriveaddresses", desc, [0, 24])
                entry["scripts"][branch] = [core("validateaddress", a)["scriptPubKey"] for a in addrs]
            vectors["types"][kind] = entry

        # Same wpkh key re-encoded as a mainnet xpub; checksum and scripts from Core on mainnet.
        tpub_body = descs[("wpkh", False)].split("#")[0]
        tpub = tpub_body.split("]")[1].split("/")[0]
        xpub = b58check_encode(bytes.fromhex("0488b21e") + b58check_decode(tpub)[4:])
        main_core = Core("main")
        try:
            mainnet = main_core("getdescriptorinfo", tpub_body.replace(tpub, xpub))["descriptor"]
            main_scripts = [main_core("validateaddress", a)["scriptPubKey"]
                            for a in main_core("deriveaddresses", mainnet, [0, 4])]
        finally:
            main_core.close()
        vectors["mainnet_wpkh"] = {"external": mainnet, "scripts": main_scripts}

        # A small chain exercising receive, spend-with-change and coinbase.
        miner = core("getnewaddress", wallet="miner")
        core("generatetoaddress", 101, miner)
        recv = core("getnewaddress", "", "bech32", wallet="subject")
        fund = core("sendtoaddress", recv, 2.0, wallet="miner")
        core("generatetoaddress", 1, miner)
        spend = core("sendtoaddress", miner, 0.5, wallet="subject")
        core("generatetoaddress", 1, miner)
        cb_addr = core("getnewaddress", "", "bech32", wallet="subject")
        cb_block = core("generatetoaddress", 1, cb_addr)[0]
        txs = {}
        for txid in (fund, spend):
            info = core("getrawtransaction", txid, True)
            txs[txid] = info["blockhash"]
        txs[core("getblock", cb_block)["tx"][0]] = cb_block
        chain_txs = []
        for txid, blockhash in txs.items():
            block = core("getblock", blockhash)
            chain_txs.append({
                "txid": txid,
                "raw": core("getrawtransaction", txid, False),
                "height": block["height"],
                "block_hash": blockhash,
                "header": core("getblockheader", blockhash, False),
                "merkle": {"block_height": block["height"], "pos": block["tx"].index(txid),
                            "siblings": merkle_proof(block["tx"], block["tx"].index(txid))},
            })
        tip = core("getblockcount")
        vectors["chain"] = {
            "tip_height": tip,
            "block_hashes": {str(h): core("getblockhash", h) for h in range(0, tip + 1)},
            "transactions": chain_txs,
            "expected_balances": core("getbalances", wallet="subject")["mine"],
            "roles": {"fund": fund, "spend": spend, "coinbase": list(txs)[2]},
        }
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        with open(OUT, "w") as f:
            json.dump(vectors, f, indent=1)
        print("wrote", OUT)
    finally:
        core.close()


if __name__ == "__main__":
    main()
