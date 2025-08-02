use dep::std::field::bn254;

// In main.nr
global LIQUIDATION_THRESHOLD: Field = 50;
global LIQUIDATION_PRECISION: Field = 100;
global PRECISION: Field = 1_000_000_000_000_000_000; // 1e18
global MIN_HEALTH_FACTOR: Field = 1_000_000_000_000_000_000; // 1e18

fn main(total_dsc_minted: pub Field, collateral_value_in_usd: pub Field) {
    if total_dsc_minted != 0 {
        let collateral_adjusted_for_threshold =
            (collateral_value_in_usd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        let health_factor = (collateral_adjusted_for_threshold * PRECISION) / total_dsc_minted;
        println(health_factor);
        let result = bn254::lt(health_factor, MIN_HEALTH_FACTOR);
        println(result);
        assert(!result);
    }
}
