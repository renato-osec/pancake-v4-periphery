// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ICLSubscriber} from "../../../src/pool-cl/interfaces/ICLSubscriber.sol";
import {CLPositionManager} from "../../../src/pool-cl/CLPositionManager.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";

/// @notice A subscriber contract that returns values from the subscriber entrypoints
contract MockCLReturnDataSubscriber is ICLSubscriber {
    CLPositionManager posm;

    uint256 public notifySubscribeCount;
    uint256 public notifyUnsubscribeCount;
    uint256 public notifyModifyLiquidityCount;
    uint256 public notifyTransferCount;

    error NotAuthorizedNotifer(address sender);

    error NotImplemented();

    uint256 memPtr;

    constructor(CLPositionManager _posm) {
        posm = _posm;
    }

    modifier onlyByPosm() {
        if (msg.sender != address(posm)) revert NotAuthorizedNotifer(msg.sender);
        _;
    }

    function notifySubscribe(uint256, bytes memory) external onlyByPosm {
        notifySubscribeCount++;
    }

    function notifyUnsubscribe(uint256) external onlyByPosm {
        notifyUnsubscribeCount++;
        uint256 _memPtr = memPtr;
        assembly {
            let fmp := mload(0x40)
            mstore(fmp, 0xBEEF)
            mstore(add(fmp, 0x20), 0xCAFE)
            return(fmp, _memPtr)
        }
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external onlyByPosm {
        notifyModifyLiquidityCount++;
    }

    function notifyTransfer(uint256, address, address) external onlyByPosm {
        notifyTransferCount++;
    }

    function setReturnDataSize(uint256 _value) external {
        memPtr = _value;
    }
}

/// @notice A subscriber contract that returns values from the subscriber entrypoints
contract MockCLRevertSubscriber is ICLSubscriber {
    CLPositionManager posm;

    error NotAuthorizedNotifer(address sender);

    error TestRevert(string);

    constructor(CLPositionManager _posm) {
        posm = _posm;
    }

    bool shouldRevert;

    modifier onlyByPosm() {
        if (msg.sender != address(posm)) revert NotAuthorizedNotifer(msg.sender);
        _;
    }

    function notifySubscribe(uint256, bytes memory) external view onlyByPosm {
        if (shouldRevert) {
            revert TestRevert("notifySubscribe");
        }
    }

    function notifyUnsubscribe(uint256) external view onlyByPosm {
        revert TestRevert("notifyUnsubscribe");
    }

    function notifyModifyLiquidity(uint256, int256, BalanceDelta) external view onlyByPosm {
        revert TestRevert("notifyModifyLiquidity");
    }

    function notifyTransfer(uint256, address, address) external view onlyByPosm {
        revert TestRevert("notifyTransfer");
    }

    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }
}
