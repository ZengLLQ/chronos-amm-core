// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ChronosMath} from "./ChronosMath.sol";

/// @title VolatilityFee
/// @notice Volatility estimation and dynamic swap fee computation for LVR mitigation
library VolatilityFee {
    uint256 internal constant BASE_FEE_BPS = 30; // 0.30%
    uint256 internal constant MIN_FEE_BPS = 5; // 0.05%
    uint256 internal constant MAX_FEE_BPS = 150; // 1.50%
    uint32 internal constant OBSERVATION_CARDINALITY = 8;
    uint256 internal constant BPS_DIVISOR = 10000;

    struct Observation {
        uint32 timestamp;
        uint256 price0Cumulative;
    }

    struct VolatilityState {
        uint32 index;
        uint32 cardinality;
        Observation[OBSERVATION_CARDINALITY] observations;
    }

    /// @notice Records a new price observation into the circular ring buffer
    function recordObservation(VolatilityState storage state, uint32 timestamp, uint256 price0Cumulative) internal {
        uint32 currentIdx = state.index;
        Observation memory last = state.observations[currentIdx];

        if (timestamp == last.timestamp) {
            return;
        }

        uint32 nextIdx = (currentIdx + 1) % OBSERVATION_CARDINALITY;
        state.observations[nextIdx] = Observation({timestamp: timestamp, price0Cumulative: price0Cumulative});
        state.index = nextIdx;
        if (state.cardinality < OBSERVATION_CARDINALITY) {
            state.cardinality += 1;
        }
    }

    /// @notice Computes dynamic swap fee based on realized price changes across recent observations
    function computeDynamicFee(VolatilityState storage state, uint32 currentTimestamp, uint256 currentPrice0Cumulative)
        internal
        view
        returns (uint256 feeBps)
    {
        if (state.cardinality < 2) {
            return BASE_FEE_BPS;
        }

        uint32 latestIdx = state.index;
        // Oldest available observation
        uint32 oldestIdx;
        if (state.cardinality < OBSERVATION_CARDINALITY) {
            oldestIdx = 0;
        } else {
            oldestIdx = (latestIdx + 1) % OBSERVATION_CARDINALITY;
        }

        Observation memory oldest = state.observations[oldestIdx];
        uint32 timeElapsed = currentTimestamp - oldest.timestamp;

        if (timeElapsed == 0) {
            return BASE_FEE_BPS;
        }

        // Average TWAP price over the window
        uint256 twapPrice = (currentPrice0Cumulative - oldest.price0Cumulative) / timeElapsed;

        // Compare TWAP with most recent observation step price
        Observation memory prev = state.observations[latestIdx];
        uint32 shortElapsed = currentTimestamp - prev.timestamp;
        if (shortElapsed == 0) {
            return BASE_FEE_BPS;
        }
        uint256 recentPrice = (currentPrice0Cumulative - prev.price0Cumulative) / shortElapsed;

        if (twapPrice == 0) {
            return BASE_FEE_BPS;
        }

        // Calculate absolute price deviation: |recentPrice - twapPrice| / twapPrice in bps
        uint256 priceDelta;
        if (recentPrice > twapPrice) {
            priceDelta = recentPrice - twapPrice;
        } else {
            priceDelta = twapPrice - recentPrice;
        }

        uint256 deviationBps = (priceDelta * BPS_DIVISOR) / twapPrice;

        // Scale fee: base + 0.5 * deviationBps
        feeBps = BASE_FEE_BPS + (deviationBps / 2);

        if (feeBps > MAX_FEE_BPS) {
            feeBps = MAX_FEE_BPS;
        } else if (feeBps < MIN_FEE_BPS) {
            feeBps = MIN_FEE_BPS;
        }
    }
}
