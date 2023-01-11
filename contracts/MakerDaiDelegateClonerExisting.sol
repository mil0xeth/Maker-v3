// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./Strategy.sol";

contract MakerDaiDelegateClonerExisting {
    address public immutable original;

    event Cloned(address indexed clone);
    event Assimilated(address indexed original);

    constructor(address _originalStrategy
    ) public {
        emit Assimilated(_originalStrategy);
        original = _originalStrategy;
    }

    function cloneMakerDaiDelegate(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _yVault,
        string memory _strategyName,
        bytes32 _ilk,
        address _gemJoin,
        address _wantToUSDOSMProxy,
        address _chainlinkWantToUSDPriceFeed
    ) external returns (address newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(original);
        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(
            _vault,
            _yVault,
            _strategyName,
            _ilk,
            _gemJoin,
            _wantToUSDOSMProxy,
            _chainlinkWantToUSDPriceFeed
        );
        Strategy(newStrategy).setKeeper(_keeper);
        Strategy(newStrategy).setRewards(_rewards);
        Strategy(newStrategy).setStrategist(_strategist);

        emit Cloned(newStrategy);
    }

    function name() external pure returns (string memory) {
        return "Yearn-Maker-v3-Cloner";
    }
}
