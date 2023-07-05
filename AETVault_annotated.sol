// SPDX-License-Identifier: MIT

contract AETVault is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public wantAddress;
    address public masterchefAddress;
    address public farmContractAddress;

    struct UserInfo {
        uint256 amount;
        uint256 shares;
        uint256 update;
        // uint256[] rewardDebt; // Reward debt. See explanation below.
    }

    struct EarnInfo {
        address token;
        uint256 amount;
    }

    mapping(address => UserInfo) public userInfo;

    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public userPending;

    address public govAddress;
    address public rToken;
    address public aetzap;
    address public lendingPool;
    bool public onlyGov = true;

    uint256 public wantLockedTotal = 0;
    uint256 public sharesTotal = 0;
    uint256 public accSushiPerShare = 0;
    uint8 public poolType = 0; // poolType == 0 lp  , poolType ===1 token ,poolType ===2 weth ,poolType ===3 aet

    address public constant maNFTs = 0x9774Ae804E6662385F5AB9b01417BC2c6E548468;

    address public constant CHR = 0x15b2fb8f08E4Ac1Ce019EADAe02eE92AeDF06851;

    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    receive() external payable {}

    /**
     * @dev Returns the total amount deposited by the users
     */

    function sharesInfo() public view returns (uint256, uint256) {
        return (wantLockedTotal, sharesTotal);
    }

    /**
     * @dev initialize ownership wantAddress masterchefAddress farmContractAddress
     * poolType rToken aetzap lendingPool
     */

    function initialize(
        address _masterchefAddress,
        address _wantAddress,
        address _farmContractAddress,
        uint8 _poolType,
        address _rToken,
        address _aetzap,
        address _lendingPool
    ) public initializer {
        Ownable.__Ownable_init();
        govAddress = msg.sender;
        wantAddress = _wantAddress;
        masterchefAddress = _masterchefAddress;
        farmContractAddress = _farmContractAddress;
        poolType = _poolType;
        rToken = _rToken;
        aetzap = _aetzap;
        lendingPool = _lendingPool;
    }

    uint256 public lastStakeAmount = 0;

    /**
     * @dev change poolType
     * // poolType == 0 lp  , poolType ===1 token ,poolType ===2 weth ,poolType ===3 aet
     */

    function changePoolType(uint8 _type) public {
        require(msg.sender == govAddress);
        poolType = _type;
    }

    /**
     * @dev change wantAddress(The token address staked by the user)
     */

    function changeWant(address _want) public onlyOwner {
        wantAddress = _want;
    }

    /**
     * @dev set lastStakeAmount to the rtoken balance
     */
    function setLastStakeAmount() public {
        require(
            msg.sender == masterchefAddress ||
                IAETVault(address(this)).isMe() ||
                msg.sender == govAddress
        );

        if (rToken != address(0x0)) {
            uint256 rBalance = IERC20(rToken).balanceOf(address(this));
            lastStakeAmount = rBalance;
        }
    }

    /**
     * @dev Determine whether this contract is in operation
     */
    function isMe() external view returns (bool) {
        if (msg.sender == address(this)) return true;
        return false;
    }

    /**
     * @dev   despoit token
     */
    function deposit(
        address _userAddress,
        uint256 _wantAmt
    ) public returns (uint256) {
        require(
            msg.sender == masterchefAddress || IAETVault(address(this)).isMe()
        );
        earn();
        onHarvest(_userAddress);

        uint256 sharesAdded = _wantAmt;
        wantLockedTotal = wantLockedTotal.add(_wantAmt);

        sharesTotal = sharesTotal.add(sharesAdded);
        IERC20(wantAddress).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );

        if (poolType == 0 && _wantAmt > 0) {
            IERC20(wantAddress).safeApprove(
                address(farmContractAddress),
                _wantAmt
            );
            IUsedLpFarm(farmContractAddress).deposit(_wantAmt);
        }
        if (poolType == 1 && _wantAmt > 0) {
            IERC20(wantAddress).safeApprove(
                address(farmContractAddress),
                _wantAmt
            );
            IUsedFarm(farmContractAddress).deposit(
                wantAddress,
                _wantAmt,
                address(this),
                0
            );
        }

        if (poolType == 2 && _wantAmt > 0) {
            IWETH(WETH).withdraw(_wantAmt);
            IUsedFarm(farmContractAddress).depositETH{value: _wantAmt}(
                lendingPool,
                address(this),
                0
            );
        }

        onRewardEarn(_userAddress, sharesAdded, 0);

        return sharesAdded;
    }

    /**
     * @dev  Determine whether approve is required
     */
    function _approveTokenIfNeeded(address token, address _router) private {
        if (IERC20(token).allowance(address(this), _router) == 0) {
            IERC20(token).safeApprove(_router, uint256(2 ** 256 - 1));
        }
    }

    /**
     * @dev  auto compounding function
     * poolType == 0 deposit lp in chronos
     * poolType == 1 deposit single token in radiant
     * poolType == 2 deposit eth in radiant
     * poolType == 3 deposit AET
     */
    function earn() public {
        require(
            msg.sender == masterchefAddress ||
                IAETVault(address(this)).isMe() ||
                msg.sender == govAddress
        );

        uint256 _sharesTotal = sharesTotal;
        uint256 rewards;

        if (poolType == 0) {
            IUsedLpFarm(farmContractAddress).withdrawAndHarvestAll();
            // zap chr to lp
            uint256 cBalance = IERC20(CHR).balanceOf(address(this));
            _approveTokenIfNeeded(CHR, aetzap);
            try IAetZap(aetzap).swapChrToLp(cBalance, wantAddress) {} catch {}

            uint256 totalToken = IERC20(wantAddress).balanceOf(address(this));
            rewards = totalToken - sharesTotal;
            if (rewards > 0) {
                IERC20(wantAddress).safeApprove(
                    address(farmContractAddress),
                    rewards
                );
                IUsedLpFarm(farmContractAddress).deposit(rewards);
            }
        } else if (poolType == 1) {
            uint256 rBalance = IERC20(rToken).balanceOf(address(this));
            rewards = rBalance - lastStakeAmount;
            IUsedFarm(farmContractAddress).withdraw(
                wantAddress,
                rBalance,
                address(this)
            );
            IERC20(wantAddress).safeApprove(
                address(farmContractAddress),
                rBalance
            );
            IUsedFarm(farmContractAddress).deposit(
                wantAddress,
                rBalance,
                address(this),
                0
            );
        } else if (poolType == 2) {
            uint256 rBalance = IERC20(rToken).balanceOf(address(this));
            rewards = rBalance - lastStakeAmount;
            IERC20(rToken).safeApprove(address(farmContractAddress), rBalance);
            IUsedFarm(farmContractAddress).withdrawETH(
                lendingPool,
                rBalance,
                address(this)
            );

            IUsedFarm(farmContractAddress).depositETH{value: rBalance}(
                lendingPool,
                address(this),
                0
            );
        }

        if (_sharesTotal > 0 && poolType != 3) {
            accSushiPerShare = accSushiPerShare.add(
                rewards.mul(1e12).div(_sharesTotal)
            );
        }
    }

    /**
     * @dev  Get user pending rewards
     */
    function pendingEarn(
        address _userAddress
    ) public view returns (EarnInfo memory) {
        UserInfo memory user = userInfo[_userAddress];
        uint256 pending;
        uint256 rewardDebt_ = rewardDebt[_userAddress];

        pending = user.shares.mul(accSushiPerShare).div(1e12).sub(rewardDebt_);
        uint256 allPending = userPending[_userAddress] + pending;

        EarnInfo memory earnInfo = EarnInfo({
            token: wantAddress,
            amount: allPending
        });

        return earnInfo;
    }

    /**
     * @dev   withdraw token
     */
    function withdraw(
        address _userAddress,
        uint256 _wantAmt
    ) public returns (uint256) {
        require(_wantAmt >= 0, "_wantAmt < 0");
        require(
            msg.sender == masterchefAddress || IAETVault(address(this)).isMe()
        );
        earn();
        onHarvest(_userAddress);
        if (wantLockedTotal < _wantAmt) {
            _wantAmt = wantLockedTotal;
        }

        uint256 sharesRemoved = _wantAmt;
        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        wantLockedTotal = wantLockedTotal.sub(_wantAmt);

        sharesTotal = sharesTotal.sub(sharesRemoved);
        if (poolType == 0) {
            earn();
            IUsedLpFarm(farmContractAddress).withdrawAndHarvestAll();
            IERC20(wantAddress).safeTransfer(masterchefAddress, _wantAmt);
            uint256 totalAmount = IERC20(wantAddress).balanceOf(address(this));
            IERC20(wantAddress).safeApprove(
                address(farmContractAddress),
                totalAmount
            );
            IUsedLpFarm(farmContractAddress).deposit(totalAmount);
        }
        if (poolType == 1) {
            IUsedFarm(farmContractAddress).withdraw(
                wantAddress,
                _wantAmt,
                address(this)
            );
            IERC20(wantAddress).safeTransfer(masterchefAddress, _wantAmt);
        }

        if (poolType == 2) {
            IERC20(rToken).safeApprove(address(farmContractAddress), _wantAmt);
            IUsedFarm(farmContractAddress).withdrawETH(
                lendingPool,
                _wantAmt,
                address(this)
            );
            IWETH(WETH).deposit{value: _wantAmt}();
            IERC20(wantAddress).safeTransfer(masterchefAddress, _wantAmt);
        }
        if (poolType == 3) {
            IERC20(wantAddress).safeTransfer(masterchefAddress, _wantAmt);
        }
        onRewardEarn(_userAddress, sharesRemoved, 1);

        return sharesRemoved;
    }

    /**
     * @dev   harvest rewards
     */
    function harvest(address _userAddress) public {
        uint256 pending = pendingEarn(_userAddress).amount;
        if (pending > 0) {
            if (poolType == 0) {
                withdraw(_userAddress, 0);

                IUsedLpFarm(farmContractAddress).withdrawAndHarvestAll();
                uint256 totalAmount = IERC20(wantAddress).balanceOf(
                    address(this)
                );
                uint256 totalAmount1 = totalAmount - pending;
                if (totalAmount1 < wantLockedTotal) {
                    return;
                }
                IERC20(wantAddress).safeTransfer(_userAddress, pending);
                IERC20(wantAddress).safeApprove(
                    address(farmContractAddress),
                    totalAmount1
                );
                IUsedLpFarm(farmContractAddress).deposit(totalAmount1);
            }
            if (poolType == 1) {
                deposit(_userAddress, 0);
                uint256 rBalance = IERC20(rToken).balanceOf(address(this));
                uint256 totalAmount1 = rBalance - pending;
                if (totalAmount1 < wantLockedTotal) {
                    return;
                }
                IUsedFarm(farmContractAddress).withdraw(
                    wantAddress,
                    pending,
                    address(this)
                );
                IERC20(wantAddress).safeTransfer(_userAddress, pending);
            }

            if (poolType == 2) {
                deposit(_userAddress, 0);
                uint256 rBalance = IERC20(rToken).balanceOf(address(this));

                uint256 totalAmount1 = rBalance - pending;
                if (totalAmount1 < wantLockedTotal) {
                    return;
                }
                IERC20(rToken).safeApprove(
                    address(farmContractAddress),
                    pending
                );
                IUsedFarm(farmContractAddress).withdrawETH(
                    lendingPool,
                    pending,
                    address(this)
                );
                _safeTransferETH(_userAddress, pending);
            }
        }

        userPending[_userAddress] = 0;
    }

    /**
     * @dev   safeTransferETH
     */

    function _safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "ETH_TRANSFER_FAILED");
    }

    /**
     * @dev   change userPending
     */

    function onHarvest(address _userAddress) internal {
        UserInfo storage user = userInfo[_userAddress];
        uint256 pending;
        uint256 rewardDebt_ = rewardDebt[_userAddress];

        pending = user.shares.mul(accSushiPerShare).div(1e12).sub(rewardDebt_);
        if (pending > 0) {
            userPending[_userAddress] = userPending[_userAddress] + pending;
        }
    }

    /**
     * @dev   change user's rewardDebt nad shares
     */
    function onRewardEarn(
        address _userAddress,
        uint256 _userSharesAdd,
        uint8 _type
    ) internal {
        UserInfo storage user = userInfo[_userAddress];
        uint256 shares = user.shares.add(_userSharesAdd);
        if (_type == 0) {
            shares = user.shares.add(_userSharesAdd);
        }
        if (_type == 1) {
            shares = user.shares.sub(_userSharesAdd);
        }
        setLastStakeAmount();
        rewardDebt[_userAddress] = shares.mul(accSushiPerShare).div(1e12);
        user.shares = shares;
    }

    /**
     * @dev   safeTokenTransfer
     */

    function safeTokenTransfer(
        address _to,
        uint256 _amt,
        address token
    ) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (_amt > bal) {
            IERC20(token).transfer(_to, bal);
        } else {
            IERC20(token).transfer(_to, _amt);
        }
    }

    /**
     * @dev   change masterchefAddress
     */
    function setMasterchef(address _masterchefAddress) public {
        require(msg.sender == govAddress, "!gov");
        masterchefAddress = _masterchefAddress;
    }

    /**
     * @dev   chage lendingPool
     */
    function setLendingPool(address _lendingPool) public {
        require(msg.sender == govAddress, "!gov");
        lendingPool = _lendingPool;
    }

    /**
     * @dev   chage rToken
     */

    function setRToken(address _rToken) public {
        require(msg.sender == govAddress, "!gov");
        rToken = _rToken;
    }

    /**
     * @dev   chage aetzap
     */

    function setAetzap(address _aetzap) public {
        require(msg.sender == govAddress, "!gov");
        aetzap = _aetzap;
    }

    /**
     * @dev   chage onlyGov
     */

    function setOnlyGov(bool _onlyGov) public {
        require(msg.sender == govAddress, "!gov");
        onlyGov = _onlyGov;
    }
}
