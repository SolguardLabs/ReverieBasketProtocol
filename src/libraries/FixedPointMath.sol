// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library FixedPointMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        return ((a - 1) / b) + 1;
    }

    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDiv(x, y, WAD);
    }

    function mulWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, y, WAD);
    }

    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDiv(x, WAD, y);
    }

    function divWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return mulDivUp(x, WAD, y);
    }

    function bps(uint256 amount, uint256 basisPoints) internal pure returns (uint256) {
        return mulDiv(amount, basisPoints, BPS);
    }

    function bpsUp(uint256 amount, uint256 basisPoints) internal pure returns (uint256) {
        return mulDivUp(amount, basisPoints, BPS);
    }

    function toWad(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount * (10 ** (18 - decimals));
        return amount / (10 ** (decimals - 18));
    }

    function fromWad(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount / (10 ** (18 - decimals));
        return amount * (10 ** (decimals - 18));
    }

    function valueOf(
        uint256 amount,
        uint8 decimals,
        uint256 priceWad
    ) internal pure returns (uint256) {
        return mulWadDown(toWad(amount, decimals), priceWad);
    }

    function amountForValue(
        uint256 valueWad,
        uint8 decimals,
        uint256 priceWad
    ) internal pure returns (uint256) {
        uint256 amountWad = divWadUp(valueWad, priceWad);
        return fromWad(amountWad, decimals);
    }

    function ratioBps(uint256 part, uint256 whole) internal pure returns (uint256) {
        if (whole == 0) return 0;
        return mulDiv(part, BPS, whole);
    }

    function wadRatio(uint256 part, uint256 whole) internal pure returns (uint256) {
        if (whole == 0) return 0;
        return mulDiv(part, WAD, whole);
    }

    function weightedAverage(
        uint256 first,
        uint256 firstWeight,
        uint256 second,
        uint256 secondWeight
    ) internal pure returns (uint256) {
        uint256 totalWeight = firstWeight + secondWeight;
        if (totalWeight == 0) return 0;
        return mulDiv(first, firstWeight, totalWeight) + mulDiv(second, secondWeight, totalWeight);
    }

    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = 1;
        uint256 y = x;
        if (y >= 0x100000000000000000000000000000000) {
            y >>= 128;
            z <<= 64;
        }
        if (y >= 0x10000000000000000) {
            y >>= 64;
            z <<= 32;
        }
        if (y >= 0x100000000) {
            y >>= 32;
            z <<= 16;
        }
        if (y >= 0x10000) {
            y >>= 16;
            z <<= 8;
        }
        if (y >= 0x100) {
            y >>= 8;
            z <<= 4;
        }
        if (y >= 0x10) {
            y >>= 4;
            z <<= 2;
        }
        if (y >= 0x8) {
            z <<= 1;
        }
        z = (z + x / z) >> 1;
        z = (z + x / z) >> 1;
        z = (z + x / z) >> 1;
        z = (z + x / z) >> 1;
        z = (z + x / z) >> 1;
        z = (z + x / z) >> 1;
        z = (z + x / z) >> 1;
        uint256 roundedDown = x / z;
        return z < roundedDown ? z : roundedDown;
    }

    function mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, denominator);
        if (mulmod(x, y, denominator) != 0) result += 1;
        return result;
    }

    function mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        if (denominator == 0) revert();
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(x, y, not(0))
            prod0 := mul(x, y)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        if (prod1 == 0) return prod0 / denominator;
        if (denominator <= prod1) revert();

        assembly {
            let remainder := mulmod(x, y, denominator)
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)

            let twos := and(denominator, sub(0, denominator))
            denominator := div(denominator, twos)
            prod0 := div(prod0, twos)
            twos := add(div(sub(0, twos), twos), 1)
            prod0 := or(prod0, mul(prod1, twos))

            let inverse := xor(mul(3, denominator), 2)
            inverse := mul(inverse, sub(2, mul(denominator, inverse)))
            inverse := mul(inverse, sub(2, mul(denominator, inverse)))
            inverse := mul(inverse, sub(2, mul(denominator, inverse)))
            inverse := mul(inverse, sub(2, mul(denominator, inverse)))
            inverse := mul(inverse, sub(2, mul(denominator, inverse)))
            inverse := mul(inverse, sub(2, mul(denominator, inverse)))

            result := mul(prod0, inverse)
        }
    }
}
