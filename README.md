# PrivateLiquidityScores — Anonymous Liquidity Scoring on Zama FHEVM

> **PrivateLiquidityScores** is a minimal protocol for **anonymous liquidity scoring** of DeFi pools. Participants submit **0–100 scores fully encrypted**, the contract aggregates them on‑chain and computes an **encrypted average** using Zama FHEVM. No individual rating is ever revealed, but everyone gets a trustworthy aggregated result.

---

## ✨ TL;DR

* 💧 **Honest scoring for liquidity pools**: any DeFi team can define a `poolId` and collect feedback from LPs, traders, or DAO members.
* 🕵️ **Full participant privacy**: every rating is sent as an FHE ciphertext; individual values are never decrypted on‑chain.
* 📊 **Averages computed over encrypted data**: the contract stores `sumEnc` and `avgEnc` as `euint32` and divides them inside FHEVM.
* 🔑 **Flexible access control for results**: the pool owner can keep the average private, grant access to specific addresses, or make it globally decryptable.
* 🌐 **Ready‑to‑use frontend**: a single `index.html` file with ethers v6 + Zama Relayer SDK that demonstrates the full flow from encrypting a rating to decrypting the average.

---

## 📚 Project Overview

### Why PrivateLiquidityScores?

Most DeFi protocols rely on **public metrics** (volume, TVL, fees) while **user experience and perceived quality are rarely measured**. When you try to collect honest ratings in a standard way, you hit several problems:

* users don’t want to leave honest feedback if it’s tied to their address;
* public, address‑linked ratings can be used against them;
* teams cannot safely ask LPs/traders: “How happy are you with this pool?”

**PrivateLiquidityScores** solves this using Zama FHEVM:

* users submit **encrypted integer scores in the range 0–100**;
* the contract **aggregates the sum and computes the average fully under encryption**;
* no individual rating is ever stored in plaintext on‑chain;
* the pool owner controls who can decrypt the final score and when.

This pattern can be plugged into any DeFi product: DEXes, lending, aggregators, DAOs, etc.

---

## 🧮 Scoring Model – How the “Result” Is Computed

> This section explains **how the final score is calculated**, what is stored where, and what the chain actually sees.

### Core Entities

* **`poolId`** — pool identifier (`bytes32`). On the frontend it’s derived as `keccak256(toUtf8Bytes("pool-usdc-eth"))`, etc.
* **`Pool`** — struct inside the contract:

  * `owner` — address of the pool owner / admin;
  * `exists` — whether the pool has been initialized;
  * `sumEnc` (`euint32`) — encrypted sum of all submitted scores;
  * `avgEnc` (`euint32`) — encrypted average score;
  * `count` (`uint32`) — public counter of submitted scores.

### Score Range

Each user submits a single integer `r` in the range **0…100**.

The contract **hard‑clamps** this value to [0, 100] using FHE operations:

```solidity
// Import external ciphertext and clamp to [0, 100]
euint8 r = FHE.fromExternal(extScore, attestation);
r = FHE.max(r, FHE.asEuint8(0));
r = FHE.min(r, FHE.asEuint8(100));
```

Even if the frontend or an attacker tries to send an out‑of‑range value, it is still projected back into the safe interval at the encrypted level.

### Encrypted Sum Accumulation

Let `r₁, r₂, ..., rₙ` be user scores (each in [0, 100]). The contract **never decrypts them**, but stores:

* `sumEnc ≈ FHE(r₁ + r₂ + ... + rₙ)`
* `count = n` (in plaintext)

Sum update logic:

```solidity
euint32 inc = FHE.asEuint32(r);
if (p.count == 0) {
    p.sumEnc = inc;
} else {
    p.sumEnc = FHE.add(p.sumEnc, inc);
}
FHE.allowThis(p.sumEnc);
```

### Encrypted Average Computation

The average rating is:

[
avg = rac{r_1 + r_2 + ... + r_n}{n}
]

On‑chain this is implemented as a homomorphic division:

```solidity
function recomputeAverage(bytes32 poolId) public {
    Pool storage p = pools[poolId];
    require(p.exists, "pool not found");

    uint32 n = p.count;
    require(n > 0, "no scores");

    p.avgEnc = FHE.div(p.sumEnc, n);

    FHE.allowThis(p.avgEnc);
    FHE.allow(p.avgEnc, p.owner); // pool owner gets read access

    emit AverageRecomputed(poolId);
}
```

* `p.avgEnc` is an **encrypted integer** (average score, truncated to an integer).
* The frontend can display it as a **float with 2 decimals** if desired (`x.xx`).

### Access to the Result – “Win” for Stakeholders

The final average score is the **main “win”** for everyone involved:

* participants know their individual ratings remain private;
* the protocol team gets a trustworthy aggregated metric;
* potential users can see a pool quality score derived from real encrypted feedback.

The contract exposes several ways to access the result:

1. `avgHandle(poolId)` — returns a **handle** (`bytes32`) to the encrypted average.
2. `FHE.allow(p.avgEnc, to)` — the owner can **grant read access** to specific addresses (`grantAvgAccess`).
3. `FHE.makePubliclyDecryptable(p.avgEnc)` — the owner can make the average **globally decryptable** (`makeAvgPublic`).

Decryption is performed **off‑chain** through the Relayer SDK using `publicDecrypt()` or `userDecrypt()`.

---

## 🖥️ UI Overview & Usage Guide

The single‑page frontend (`index.html`) is split into several logical cards.

### 1. Header

Elements:

* **Logo**: `Anonymous Liquidity Scoring`.
* **Network badge**: `Network: Sepolia`.
* **Contract badge**: `Contract: 0x...` (shortened address).
* **`Connect Wallet` button**:

  * connects MetaMask / compatible wallet via `BrowserProvider` from `ethers`;
  * checks the network and, if needed, asks to switch to Sepolia (`chainId = 11155111`).

### 2. Submit Score (encrypted)

Left‑hand card — main flow for regular users.

Fields:

* **Pool ID (string)** — human readable identifier of the pool, for example:

  * `pool-usdc-eth`
  * `pool-stable-curve`
  * `pool-dao-xyz`

  On the frontend it is mapped to `bytes32`:

  ```ts
  const pool = keccak256(toUtf8Bytes(serviceIdStr.value || "default"));
  ```

* **Score (0..100)** — your rating for the pool.

Button:

* **`Encrypt & Submit`**:

  1. Initializes the FHE client via `createInstance({ ...SepoliaConfig, relayerUrl, network: window.ethereum })`.

  2. Creates an encrypted input:

     ```ts
     const enc = r.createEncryptedInput(contractAddress, userAddress);
     if (enc.add8) enc.add8(BigInt(num));
     else enc.addUint8(BigInt(num));

     const { handles, inputProof } = await enc.encrypt();
     ```

  3. Sends the `submitScore(poolId, handle, attestation)` transaction to the contract.

  4. Shows transaction hash and status (`Encrypting…`, `Sending tx…`, `Done`).

**For the end user:** type `Pool ID`, choose a number 0–100, click one button.

### 3. Recompute Average / Get Handle

Top‑right card — tools for the pool owner (or advanced users / scripts).

Fields:

* **Pool ID** — same string pool identifier as in the Submit card.

Buttons:

* `recomputeAverage()` — sends a transaction:

  * recomputes the encrypted average `avgEnc = sumEnc / count`;
  * gives the pool owner read access to the refreshed `avgEnc`;
  * updates status (`Submitting…` → `Recomputed`).

* `avgHandle()` — calls `avgHandle(poolId)` and prints the returned `bytes32` into `<pre id="avgHandleBox">`.

### 4. Decrypt Average

Bottom‑left card — decrypting the encrypted average.

Buttons:

1. **Public decrypt**

   * Works if the owner has previously called `makeAvgPublic(poolId)`.
   * Uses `relayer.publicDecrypt([handle])`.
   * Displays the decrypted score in `Average (float with 2 decimals)`.

2. **User decrypt (EIP‑712)**

   * Used when the average is **not public**, but the caller has been granted access via `FHE.allow`.

   * The frontend does roughly:

     ```ts
     const kp = r.generateKeypair();
     const startTs = Math.floor(Date.now() / 1000).toString();
     const days = "7";

     const eip = r.createEIP712(
       kp.publicKey,
       [contractAddress],
       startTs,
       days
     );

     const signature = await signer.signTypedData(
       eip.domain,
       { UserDecryptRequestVerification: eip.types.UserDecryptRequestVerification },
       eip.message
     );

     const out = await r.userDecrypt(
       [{ handle: h, contractAddress }],
       kp.privateKey,
       kp.publicKey,
       signature.replace(/^0x/, ""),
       [contractAddress],
       userAddress,
       startTs,
       days
     );
     ```

   * Then the UI converts the decrypted value to a number and renders it with two decimal places.

### 5. Ownership

Bottom‑right card — for pool owners only.

Fields:

* **Pool ID** — string that will be hashed into `bytes32`.
* **New owner** — address of the new owner (`0x...`).

Buttons:

* `setPoolOwner`:

  * if the pool does not exist yet, initializes it (creates the `Pool` struct, zeroes encrypted fields, and grants contract access to them);
  * if the pool exists, only the **current `owner`** can change it;
  * status: `Submitting…` → `Owner set`.

* `makeAvgPublic`:

  * calls `makeAvgPublic(poolId)`;
  * marks `avgEnc` as **publicly decryptable** by anyone;
  * status: `Avg is public now`.

---

## 🚶‍♀️ Step‑by‑Step Guide

### For Pool Owners (DeFi Teams)

1. **Create a pool**

   * Pick a string pool ID (e.g. `pool-usdc-eth`).
   * In the **Ownership** card:

     * enter the ID in `Pool ID`;
     * set `New owner` to your address (or a DAO / admin contract address);
     * click `setPoolOwner` and wait for confirmation.

2. **Collect ratings**

   * Share the string `Pool ID` with your users.
   * Users open the UI, connect their wallet and submit ratings through **Submit Score (encrypted)**.

3. **Recompute the average**

   * In **Recompute Average / Get Handle**:

     * enter the same `Pool ID`;
     * click `recomputeAverage()` and wait for the transaction.

4. **Get a handle & decrypt**

   * Click `avgHandle()` and copy the handle.
   * Use **Public decrypt** (if you switched the pool to public) or **User decrypt (EIP‑712)** if access is restricted.

5. **Make the result public (optional)**

   * In **Ownership**, click `makeAvgPublic`.
   * Anyone can now take the handle and decrypt the average using `publicDecrypt`.

### For Regular Users

1. Open the dApp and click **Connect Wallet**.
2. Make sure the network is **Sepolia** (the UI will prompt you if a switch is needed).
3. In **Submit Score (encrypted)**:

   * paste the string `Pool ID` you were given;
   * pick a number `0–100` in the `Score` field;
   * click **Encrypt & Submit**.
4. Wait for the status `Done` — your encrypted rating is now part of the aggregated score.

---

## 🏗️ Project Structure

A simple repository layout, optimized to showcase the FHEVM pattern (adapt to your tooling: Foundry, Hardhat, etc.):

```text
.
├── contracts/
│   └── PrivateLiquidityScores.sol       # Core FHEVM scoring contract
├── frontend/
│   └── index.html                       # Single‑page UI with ethers v6 + Relayer SDK
├── scripts/                             # (optional) deployment / pool setup scripts
│   └── deploy.ts / deploy.js
├── README.md                            # This file
└── package.json / foundry.toml / ...    # Build & test tooling (optional)
```

### Contract: `PrivateLiquidityScores.sol`

Key implementation details:

* Inherits from `ZamaEthereumConfig` to run inside FHEVM.

* Uses only official Zama libraries:

  ```solidity
  import { FHE, euint8, euint32, externalEuint8 } from "@fhevm/solidity/lib/FHE.sol";
  import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
  ```

* Clear separation between:

  * **encrypted fields** (`sumEnc`, `avgEnc`);
  * **public metadata** (`count`, `owner`).

* Uses `FHE.allowThis` / `FHE.allow` to manage access control for ciphertexts.

* Getter functions return **only handles** (`bytes32`) instead of plaintext values.

### Frontend: `index.html`

* Plain HTML + CSS, no framework — easy to read and integrate.
* `ethers@6.13.4` for EVM interactions.
* `@zama-fhe/relayer-sdk` (via CDN) for FHE operations:

  * `initSDK()` — load WASM;
  * `createInstance(SepoliaConfig, { relayerUrl, network })` — create client instance;
  * `createEncryptedInput(...)` + `add8` / `addUint8` — encrypt ratings;
  * `publicDecrypt(...)` & `userDecrypt(...)` — decrypt averages.
* UI status messages (`Encrypting…`, `userDecrypt…`, `Error: ...`) at each step to keep users informed.

---

## 🔐 Privacy Model

Inspired by the best practices seen in projects like Zolymarket, FHEdback, Ratings, and PayProof.

**The contract / blockchain DO NOT know:**

* which exact scores individual addresses submitted;
* how many times a given user scored a pool (unless you add extra logic);
* any history of rating changes.

**The contract / blockchain DO know:**

* that an encrypted rating was submitted (via `ScoreSubmitted` events);
* the total number of ratings per `poolId` (`count`);
* the encrypted sum `sumEnc` and encrypted average `avgEnc`;
* the current pool owner `owner`.

**Access to the average** is controlled as follows:

* **Private mode**: only the owner and explicitly allowed addresses can decrypt the average.
* **Public mode**: the owner calls `makeAvgPublic`, after which any frontend can decrypt it via `publicDecrypt`.

As a result, **individual ratings are never revealed**, while the aggregated metric remains accessible and verifiable.

---

## 🚀 Future Directions

A few directions that are straightforward to build on top of this protocol:

* **On‑chain KPIs**: use the average score as an input into token distribution, fee discounts, or farming boosts.
* **DAO governance**: treat pool score as a trust signal in governance proposals.
* **Aggregators / dashboards**: sort and filter pools by their encrypted‑then‑decrypted reputation metrics.
* **Custom scales**: support different rating scales (0–10, 0–1000) with frontend mapping.

---

## 📄 License

The contract is marked with `// SPDX-License-Identifier: MIT`. The repository can be distributed under the MIT license, similar to most projects in the Zama FHEVM ecosystem.
