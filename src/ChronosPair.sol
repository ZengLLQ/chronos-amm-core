// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IChronosPair} from "./interfaces/IChronosPair.sol";
import {IChronosFactory} from "./interfaces/IChronosFactory.sol";
import {IChronosCallee} from "./interfaces/IChronosCallee.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC3156FlashBorrower} from "./interfaces/IERC3156FlashBorrower.sol";
import {ChronosERC20} from "./ChronosERC20.sol";
import {ChronosMath} from "./libraries/ChronosMath.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {VolatilityFee} from "./libraries/VolatilityFee.sol";

/// @title ChronosPair
/// @notice Core AMM pool combining Constant Product AMM, TWAMM virtual order execution, and LVR-mitigating dynamic volatility fees
contract ChronosPair is IChronosPair, ChronosERC20 {
    using SafeTransferLib for address;
    using VolatilityFee for VolatilityFee.VolatilityState;

    error PoolLocked();
    error NotFactory();
    error AlreadyInitialized();
    error ZeroAddress();
    error ZeroLiquidity();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InvariantViolated();
    error Overflow();
    error InvalidOrderInterval();
    error OrderNotActive();
    error Unauthorized();
    error UnsupportedToken();
    error FlashLoanCallbackFailed();
    error FlashLoanRepaymentDeficit();

    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 public constant INTERVAL_LENGTH = 10; // 10 seconds per TWAMM epoch
    bytes32 private constant FLASH_LOAN_RETURN = keccak256("ERC3156FlashBorrower.onFlashLoan");

    address public immutable factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public kLast;

    uint256 private unlocked = 1;
    modifier lock() {
        if (unlocked != 1) revert PoolLocked();
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // Dynamic fee state
    VolatilityFee.VolatilityState internal volatilityState;

    // TWAMM internal state
    struct InternalOrderPool {
        uint256 currentSalesRate;
        mapping(uint256 => uint256) salesRateStartingAtInterval;
        mapping(uint256 => uint256) salesRateEndingAtInterval;
        mapping(uint256 => uint256) rewardFactor;
    }

    InternalOrderPool internal pool0For1;
    InternalOrderPool internal pool1For0;

    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId = 1;
    uint256 public lastVirtualExecutionInterval;

    uint256 public orderPool0Balance;
    uint256 public orderPool1Balance;

    constructor() {
        factory = msg.sender;
    }

    /// @notice Initialize tokens for the pair (callable once by factory)
    function initialize(address _token0, address _token1) external {
        if (msg.sender != factory) revert NotFactory();
        if (token0 != address(0) || token1 != address(0)) revert AlreadyInitialized();
        if (_token0 == address(0) || _token1 == address(0) || _token0 == _token1) revert ZeroAddress();

        token0 = _token0;
        token1 = _token1;
        lastVirtualExecutionInterval = block.timestamp / INTERVAL_LENGTH;
    }

    function intervalLength() external pure returns (uint256) {
        return INTERVAL_LENGTH;
    }

    function currentInterval() public view returns (uint256) {
        return block.timestamp / INTERVAL_LENGTH;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function currentDynamicFeeBps() public view returns (uint256) {
        uint32 currentTimestamp = uint32(block.timestamp % 2 ** 32);
        return volatilityState.computeDynamicFee(currentTimestamp, price0CumulativeLast);
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    function getOrderPool(bool isToken0) external view returns (uint256 currentSalesRate, uint256 currentRewardFactor) {
        uint256 curInterval = currentInterval();
        if (isToken0) {
            currentSalesRate = pool0For1.currentSalesRate;
            currentRewardFactor = pool0For1.rewardFactor[curInterval];
        } else {
            currentSalesRate = pool1For0.currentSalesRate;
            currentRewardFactor = pool1For0.rewardFactor[curInterval];
        }
    }

    /// @dev Update reserves and, on the first call per block, price accumulators
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert Overflow();
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast;
        }

        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            unchecked {
                price0CumulativeLast += uint256(ChronosMath.divWad(_reserve1, _reserve0)) * timeElapsed;
                price1CumulativeLast += uint256(ChronosMath.divWad(_reserve0, _reserve1)) * timeElapsed;
            }
            volatilityState.recordObservation(blockTimestamp, price0CumulativeLast);
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    /// @dev Mint fee to factory feeTo address if protocol fee is enabled
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IChronosFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast;
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = ChronosMath.sqrt(uint256(_reserve0) * _reserve1);
                uint256 rootKLast = ChronosMath.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply * (rootK - rootKLast);
                    uint256 denominator = (rootK * 5) + rootKLast;
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // =========================================================
    //                    TWAMM CORE ENGINE
    // =========================================================

    /// @notice Execute TWAMM virtual orders lazily up to the current interval
    function executeTwamm() public lock {
        _executeTwammInternal();
    }

    function _executeTwammInternal() internal {
        uint256 curInterval = currentInterval();
        uint256 targetInterval = curInterval;
        uint256 lastInterval = lastVirtualExecutionInterval;

        if (targetInterval <= lastInterval) {
            return;
        }

        // Check if pool has liquidity to execute TWAMM virtual swaps
        if (reserve0 == 0 || reserve1 == 0) {
            lastVirtualExecutionInterval = targetInterval;
            return;
        }

        uint256 curReserve0 = reserve0;
        uint256 curReserve1 = reserve1;
        uint256 dynamicFee = currentDynamicFeeBps();

        uint256 activeRate0 = pool0For1.currentSalesRate;
        uint256 activeRate1 = pool1For0.currentSalesRate;

        for (uint256 i = lastInterval + 1; i <= targetInterval; i++) {
            // Apply new scheduled order rates starting at interval i
            activeRate0 += pool0For1.salesRateStartingAtInterval[i];
            activeRate1 += pool1For0.salesRateStartingAtInterval[i];

            uint256 in0 = activeRate0;
            uint256 in1 = activeRate1;

            if (in0 > 0 || in1 > 0) {
                (uint256 out0, uint256 out1, uint256 newReserve0, uint256 newReserve1) =
                    ChronosMath.computeVirtualSwap(in0, in1, curReserve0, curReserve1, dynamicFee);

                curReserve0 = newReserve0;
                curReserve1 = newReserve1;

                // Update reward factors (proceeds per unit sale rate)
                if (activeRate0 > 0) {
                    pool0For1.rewardFactor[i] = pool0For1.rewardFactor[i - 1] + (out1 * 1e18) / activeRate0;
                } else {
                    pool0For1.rewardFactor[i] = pool0For1.rewardFactor[i - 1];
                }

                if (activeRate1 > 0) {
                    pool1For0.rewardFactor[i] = pool1For0.rewardFactor[i - 1] + (out0 * 1e18) / activeRate1;
                } else {
                    pool1For0.rewardFactor[i] = pool1For0.rewardFactor[i - 1];
                }

                emit TwammExecuted(i - 1, i, in0, out1, in1, out0);
            } else {
                pool0For1.rewardFactor[i] = pool0For1.rewardFactor[i - 1];
                pool1For0.rewardFactor[i] = pool1For0.rewardFactor[i - 1];
            }

            // Decrement ending order rates
            activeRate0 -= pool0For1.salesRateEndingAtInterval[i];
            activeRate1 -= pool1For0.salesRateEndingAtInterval[i];
        }

        pool0For1.currentSalesRate = activeRate0;
        pool1For0.currentSalesRate = activeRate1;
        lastVirtualExecutionInterval = targetInterval;

        _update(curReserve0, curReserve1, reserve0, reserve1);
    }

    /// @notice Submit a long-term TWAMM order
    function submitLongTermOrder(bool isToken0, uint256 amountIn, uint256 numberOfIntervals)
        external
        lock
        returns (uint256 orderId)
    {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (numberOfIntervals == 0) revert InvalidOrderInterval();

        _executeTwammInternal();

        address inputToken = isToken0 ? token0 : token1;
        inputToken.safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 curInterval = currentInterval();
        uint256 startInterval = curInterval + 1;
        uint256 endInterval = startInterval + numberOfIntervals;
        uint256 saleRate = amountIn / numberOfIntervals;
        if (saleRate == 0) revert InsufficientInputAmount();

        orderId = nextOrderId++;
        orders[orderId] = Order({
            owner: msg.sender,
            saleRate: saleRate,
            startInterval: startInterval,
            endInterval: endInterval,
            lastClaimedInterval: startInterval,
            isToken0: isToken0
        });

        if (isToken0) {
            orderPool0Balance += amountIn;
            pool0For1.salesRateStartingAtInterval[startInterval] += saleRate;
            pool0For1.salesRateEndingAtInterval[endInterval] += saleRate;
        } else {
            orderPool1Balance += amountIn;
            pool1For0.salesRateStartingAtInterval[startInterval] += saleRate;
            pool1For0.salesRateEndingAtInterval[endInterval] += saleRate;
        }

        emit LongTermOrderSubmitted(orderId, msg.sender, isToken0, amountIn, startInterval, endInterval);
    }

    /// @notice Claim purchased tokens from an active or finished TWAMM order
    function claimLongTermOrder(uint256 orderId) external lock returns (uint256 purchasedClaim) {
        _executeTwammInternal();
        purchasedClaim = _claimOrder(orderId, msg.sender);
    }

    function _claimOrder(uint256 orderId, address recipient) internal returns (uint256 purchasedClaim) {
        Order storage order = orders[orderId];
        if (order.owner == address(0)) revert Unauthorized();
        if (order.owner != recipient) revert Unauthorized();

        uint256 lastInterval = lastVirtualExecutionInterval;
        if (lastInterval <= order.lastClaimedInterval) {
            return 0;
        }

        uint256 claimUntil = lastInterval < order.endInterval ? lastInterval : order.endInterval;
        if (claimUntil <= order.lastClaimedInterval) {
            return 0;
        }

        InternalOrderPool storage pool = order.isToken0 ? pool0For1 : pool1For0;
        uint256 rewardDelta = pool.rewardFactor[claimUntil] - pool.rewardFactor[order.lastClaimedInterval];
        purchasedClaim = (order.saleRate * rewardDelta) / 1e18;

        order.lastClaimedInterval = claimUntil;

        if (purchasedClaim > 0) {
            address outputToken = order.isToken0 ? token1 : token0;
            if (order.isToken0) {
                if (orderPool1Balance >= purchasedClaim) {
                    orderPool1Balance -= purchasedClaim;
                } else {
                    orderPool1Balance = 0;
                }
            } else {
                if (orderPool0Balance >= purchasedClaim) {
                    orderPool0Balance -= purchasedClaim;
                } else {
                    orderPool0Balance = 0;
                }
            }
            outputToken.safeTransfer(recipient, purchasedClaim);
        }

        emit LongTermOrderClaimed(orderId, recipient, purchasedClaim);
    }

    /// @notice Cancel a long-term TWAMM order, claiming accrued proceeds and refunding unexecuted tokens
    function cancelLongTermOrder(uint256 orderId) external lock returns (uint256 unsoldRefund, uint256 purchasedClaim) {
        _executeTwammInternal();

        Order storage order = orders[orderId];
        if (order.owner == address(0)) revert Unauthorized();
        if (order.owner != msg.sender) revert Unauthorized();

        // Claim any earned proceeds up to lastVirtualExecutionInterval
        purchasedClaim = _claimOrder(orderId, msg.sender);

        uint256 lastInterval = lastVirtualExecutionInterval;
        if (order.endInterval > lastInterval) {
            uint256 effectiveStart = order.startInterval > lastInterval ? order.startInterval : lastInterval;
            uint256 unexecutedIntervals = order.endInterval > effectiveStart ? order.endInterval - effectiveStart : 0;
            unsoldRefund = unexecutedIntervals * order.saleRate;

            InternalOrderPool storage pool = order.isToken0 ? pool0For1 : pool1For0;

            if (order.startInterval > lastInterval) {
                pool.salesRateStartingAtInterval[order.startInterval] -= order.saleRate;
            } else {
                pool.currentSalesRate -= order.saleRate;
            }
            pool.salesRateEndingAtInterval[order.endInterval] -= order.saleRate;

            order.endInterval = lastInterval;

            if (unsoldRefund > 0) {
                address inputToken = order.isToken0 ? token0 : token1;
                if (order.isToken0) {
                    if (orderPool0Balance >= unsoldRefund) {
                        orderPool0Balance -= unsoldRefund;
                    } else {
                        orderPool0Balance = 0;
                    }
                } else {
                    if (orderPool1Balance >= unsoldRefund) {
                        orderPool1Balance -= unsoldRefund;
                    } else {
                        orderPool1Balance = 0;
                    }
                }
                inputToken.safeTransfer(msg.sender, unsoldRefund);
            }
        }

        emit LongTermOrderCancelled(orderId, msg.sender, unsoldRefund, purchasedClaim);
    }

    // =========================================================
    //                 STANDARD AMM LIQUIDITY & SWAPS
    // =========================================================

    /// @notice Low-level liquidity minting
    function mint(address to) external lock returns (uint256 liquidity) {
        _executeTwammInternal();

        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this)) - orderPool0Balance;
        uint256 balance1 = IERC20(token1).balanceOf(address(this)) - orderPool1Balance;
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply;

        if (_totalSupply == 0) {
            liquidity = ChronosMath.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // Permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = ChronosMath.min((amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1);
        }

        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @notice Low-level liquidity burning
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        _executeTwammInternal();

        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this)) - orderPool0Balance;
        uint256 balance1 = IERC20(_token1).balanceOf(address(this)) - orderPool1Balance;
        uint256 liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply;

        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        _burn(address(this), liquidity);
        _token0.safeTransfer(to, amount0);
        _token1.safeTransfer(to, amount1);

        balance0 = IERC20(_token0).balanceOf(address(this)) - orderPool0Balance;
        balance1 = IERC20(_token1).balanceOf(address(this)) - orderPool1Balance;

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0) * reserve1;
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @notice Core swap function with dynamic volatility fees and flash swap callback
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external lock {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        _executeTwammInternal();

        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert InsufficientLiquidityBurned();

        uint256 balance0;
        uint256 balance1;
        {
            address _token0 = token0;
            address _token1 = token1;
            if (to == _token0 || to == _token1) revert ZeroAddress();

            // Optimistically transfer tokens
            if (amount0Out > 0) _token0.safeTransfer(to, amount0Out);
            if (amount1Out > 0) _token1.safeTransfer(to, amount1Out);

            // Flash swap callback
            if (data.length > 0) {
                IChronosCallee(to).chronosCall(msg.sender, amount0Out, amount1Out, data);
            }

            balance0 = IERC20(_token0).balanceOf(address(this)) - orderPool0Balance;
            balance1 = IERC20(_token1).balanceOf(address(this)) - orderPool1Balance;
        }

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        uint256 dynamicFee = currentDynamicFeeBps();
        {
            // Verify constant product invariant with dynamic volatility fee
            uint256 balance0Adjusted = (balance0 * 10000) - (amount0In * dynamicFee);
            uint256 balance1Adjusted = (balance1 * 10000) - (amount1In * dynamicFee);
            if (balance0Adjusted * balance1Adjusted < uint256(_reserve0) * _reserve1 * (10000 ** 2)) {
                revert InvariantViolated();
            }
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to, dynamicFee);
    }

    /// @notice Force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0;
        address _token1 = token1;
        _token0.safeTransfer(to, IERC20(_token0).balanceOf(address(this)) - orderPool0Balance - reserve0);
        _token1.safeTransfer(to, IERC20(_token1).balanceOf(address(this)) - orderPool1Balance - reserve1);
    }

    /// @notice Force reserves to match balances
    function sync() external lock {
        _executeTwammInternal();
        _update(
            IERC20(token0).balanceOf(address(this)) - orderPool0Balance,
            IERC20(token1).balanceOf(address(this)) - orderPool1Balance,
            reserve0,
            reserve1
        );
    }

    // =========================================================
    //              ERC-3156 FLASH LOAN IMPLEMENTATION
    // =========================================================

    function maxFlashLoan(address token) external view override returns (uint256) {
        if (token == token0) {
            return reserve0;
        } else if (token == token1) {
            return reserve1;
        }
        return 0;
    }

    function flashFee(address token, uint256 amount) public view override returns (uint256) {
        if (token != token0 && token != token1) revert UnsupportedToken();
        uint256 dynamicFee = currentDynamicFeeBps();
        return (amount * dynamicFee) / 10000;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        lock
        returns (bool)
    {
        if (token != token0 && token != token1) revert UnsupportedToken();
        _executeTwammInternal();

        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        if ((token == token0 && amount > _reserve0) || (token == token1 && amount > _reserve1)) {
            revert InsufficientLiquidityBurned();
        }

        uint256 fee = flashFee(token, amount);

        // Optimistically transfer loan
        token.safeTransfer(address(receiver), amount);

        // Execute borrower callback
        if (receiver.onFlashLoan(msg.sender, token, amount, fee, data) != FLASH_LOAN_RETURN) {
            revert FlashLoanCallbackFailed();
        }

        // Pull repayment amount + fee
        token.safeTransferFrom(address(receiver), address(this), amount + fee);

        uint256 balance0 = IERC20(token0).balanceOf(address(this)) - orderPool0Balance;
        uint256 balance1 = IERC20(token1).balanceOf(address(this)) - orderPool1Balance;

        // Verify reserves increased by at least fee
        if (token == token0) {
            if (balance0 < _reserve0 + fee) revert FlashLoanRepaymentDeficit();
        } else {
            if (balance1 < _reserve1 + fee) revert FlashLoanRepaymentDeficit();
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        return true;
    }
}
