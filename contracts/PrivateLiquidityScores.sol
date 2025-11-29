// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/* Zama FHEVM */
import { FHE, euint8, euint32, externalEuint8 } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title PrivateLiquidityScores — anonymous, aggregated liquidity scoring for DeFi pools
/// @notice Participants submit encrypted 0..100 scores; contract aggregates sum and computes encrypted average.
/// @dev Uses only Zama official libs; no FHE ops in view except returning bytes32 handles.
contract PrivateLiquidityScores is ZamaEthereumConfig {
    struct Pool {
        address owner;    // controller of access policy for this pool
        bool    exists;
        euint32 sumEnc;   // encrypted sum of ratings (ratings are clamped to 0..100)
        euint32 avgEnc;   // encrypted average: sum / count
        uint32  count;    // public counter
    }

    mapping(bytes32 => Pool) private pools; // poolId => Pool

    /* ─── Events ─── */
    event PoolOwnerSet(bytes32 indexed poolId, address indexed owner);
    event ScoreSubmitted(bytes32 indexed poolId, uint32 newCount);
    event AverageRecomputed(bytes32 indexed poolId);
    event AvgAccessGranted(bytes32 indexed poolId, address indexed to);
    event AvgMadePublic(bytes32 indexed poolId);

    /* ─── Admin: set or change pool owner ───
       - First time: anyone may set owner (bootstrap).
       - Later: only current owner may change.
    */
    function setPoolOwner(bytes32 poolId, address newOwner) external {
        require(newOwner != address(0), "bad owner");
        Pool storage p = pools[poolId];
        if (!p.exists) {
            p.exists = true;
            p.owner = newOwner;
            // initialize encrypted fields to zero
            p.sumEnc = FHE.asEuint32(0);
            p.avgEnc = FHE.asEuint32(0);
            FHE.allowThis(p.sumEnc);
            FHE.allowThis(p.avgEnc);
        } else {
            require(msg.sender == p.owner, "not owner");
            p.owner = newOwner;
        }
        emit PoolOwnerSet(poolId, newOwner);
    }

    /* ─── Submit an encrypted score (0..100) ───
       - extScore: external encrypted uint8 + attestation from Gateway
       - Score is clamped to [0,100], added into encrypted sum; public counter is incremented.
       - We purposely do *not* store per-user identity on-chain (anonymity of participants).
    */
    function submitScore(
        bytes32 poolId,
        externalEuint8 extScore,
        bytes calldata attestation
    ) external {
        Pool storage p = pools[poolId];
        require(p.exists && p.owner != address(0), "pool not configured");

        // Import external ciphertext and clamp to [0, 100]
        euint8 r = FHE.fromExternal(extScore, attestation);
        r = FHE.max(r, FHE.asEuint8(0));
        r = FHE.min(r, FHE.asEuint8(100));

        // Accumulate into encrypted sum (promote to euint32)
        euint32 inc = FHE.asEuint32(r);

        if (p.count == 0) {
            p.sumEnc = inc;
        } else {
            p.sumEnc = FHE.add(p.sumEnc, inc);
        }

        // Persist ACL so future txs in this contract can use it
        FHE.allowThis(p.sumEnc);

        unchecked { p.count += 1; } // public metadata only

        emit ScoreSubmitted(poolId, p.count);
    }

    /* ─── Compute/refresh encrypted average ───
       - avgEnc = sumEnc / count
       - Grants the pool owner read access to the refreshed average handle.
    */
    function recomputeAverage(bytes32 poolId) public {
        Pool storage p = pools[poolId];
        require(p.exists, "pool not found");
        uint32 n = p.count;
        require(n > 0, "no scores");

        p.avgEnc = FHE.div(p.sumEnc, n);

        // Keep contract access; allow pool owner as a reader
        FHE.allowThis(p.avgEnc);
        FHE.allow(p.avgEnc, p.owner);

        emit AverageRecomputed(poolId);
    }

    /* ─── Access control helpers for avg ─── */

    /// @notice Grant read access to the encrypted average for an address.
    function grantAvgAccess(bytes32 poolId, address to) external {
        require(to != address(0), "bad addr");
        Pool storage p = pools[poolId];
        require(msg.sender == p.owner, "not owner");
        FHE.allow(p.avgEnc, to);
        emit AvgAccessGranted(poolId, to);
    }

    /// @notice Make the average publicly decryptable by anyone (global read).
    function makeAvgPublic(bytes32 poolId) external {
        Pool storage p = pools[poolId];
        require(msg.sender == p.owner, "not owner");
        FHE.makePubliclyDecryptable(p.avgEnc);
        emit AvgMadePublic(poolId);
    }

    /* ─── Getters (handles only; no plaintext leaks) ─── */

    /// @notice Encrypted average handle (use userDecrypt/publicDecrypt off-chain).
    function avgHandle(bytes32 poolId) external view returns (bytes32) {
        return FHE.toBytes32(pools[poolId].avgEnc);
    }

    /// @notice Encrypted sum handle (optional diagnostics/analytics).
    function sumHandle(bytes32 poolId) external view returns (bytes32) {
        return FHE.toBytes32(pools[poolId].sumEnc);
    }

    /// @notice Public ratings count (plaintext).
    function ratingsCount(bytes32 poolId) external view returns (uint32) {
        return pools[poolId].count;
    }

    /// @notice Current pool owner (plaintext).
    function poolOwner(bytes32 poolId) external view returns (address) {
        return pools[poolId].owner;
    }

    /// @notice Optional: contract version tag.
    function version() external pure returns (string memory) {
        return "PrivateLiquidityScores/1.0.0";
    }
}
