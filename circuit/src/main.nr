global LIQUIDATION_THRESHOLD: Field = 50;
global LIQUIDATION_PRECISION: Field = 100;
global PRECISION: Field = 1_000_000_000_000_000_000; // 1e18
global MIN_HEALTH_FACTOR: Field = 1_000_000_000_000_000_000; // 1e18

/*
 * @param total_dsc_minted The total amount of DSC the user has minted.
 * @param collateral_value_in_usd The total value in USD of the user's collateral.
 *
 * This function proves that the health factor calculated from the public inputs
 * is greater than or equal to the minimum required health factor.
*/
fn main(total_dsc_minted: pub Field, collateral_value_in_usd: pub Field) {
    if total_dsc_minted != 0 {
        let collateral_adjusted_for_threshold =
            (collateral_value_in_usd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        let health_factor = (collateral_adjusted_for_threshold * PRECISION) / total_dsc_minted;

        assert(health_factor as u64 >= MIN_HEALTH_FACTOR as u64);
    }
    // If total_dsc_minted == 0, the health factor is considered infinite and valid, so we add no constraint.
}

#[test]
fn test_main() {
    let total_dsc_minted = 100 * 1_000_000_000_000_000_000;
    let collateral_value_in_usd = 200_000_000_000_000_000_000;

    main(total_dsc_minted, collateral_value_in_usd);
}

#[test]
fn test_main2() {
    let total_dsc_minted = 0;
    let collateral_value_in_usd = 200_000_000_000_000_000_000;

    main(total_dsc_minted, collateral_value_in_usd);
}
