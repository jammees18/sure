require "test_helper"

class IbkrAccount::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "IBKR Brokerage",
      balance: 0,
      cash_balance: 0,
      currency: "CHF",
      accountable: Investment.new(subtype: "brokerage")
    )
    @ibkr_account = @family.ibkr_items.create!(
      name: "IBKR",
      query_id: "QUERY123",
      token: "TOKEN123"
    ).ibkr_accounts.create!(
      name: "Main",
      ibkr_account_id: "U1234567",
      currency: "CHF"
    )
    @ibkr_account.ensure_account_provider!(@account)
    @security = securities(:aapl)
    @report_date = Date.new(2026, 5, 8)
  end

  test "inserts the broker snapshot price for Date.current when no price row exists" do
    assert_difference -> { Security::Price.where(security: @security).count }, 1 do
      process_holding
    end

    snapshot = Security::Price.find_by!(security: @security, date: Date.current, currency: "USD")
    assert_equal BigDecimal("150.00"), snapshot.price
  end

  test "does not overwrite an existing price for the same security date and currency" do
    existing = Security::Price.create!(
      security: @security,
      date: Date.current,
      currency: "USD",
      price: BigDecimal("149.25")
    )

    assert_no_difference -> { Security::Price.where(security: @security).count } do
      process_holding
    end

    assert_equal BigDecimal("149.25"), existing.reload.price
  end

  test "inserts a broker price when the existing row has another currency" do
    existing = Security::Price.create!(
      security: @security,
      date: @report_date,
      currency: "EUR",
      price: BigDecimal("140.00")
    )

    assert_difference -> { Security::Price.where(security: @security).count }, 1 do
      process_holding
    end

    snapshot = Security::Price.find_by!(security: @security, date: Date.current, currency: "USD")
    assert_equal BigDecimal("150.00"), snapshot.price
    assert_equal BigDecimal("140.00"), existing.reload.price
  end

  test "uses the normalized holding price for a dashed bond ticker" do
    ticker = "ACME-5.0-01/15/30"
    process_holding(
      "asset_category" => "BOND",
      "conid" => "999001",
      "security_id" => "US999001BOND",
      "symbol" => ticker,
      "position" => "12000",
      "mark_price" => "96.722",
      "cost_basis_price" => "96.722"
    )

    security = Security.find_by!(ticker: ticker)
    holding = @account.holdings.find_by!(security: security, date: @report_date, currency: "USD")
    snapshot = Security::Price.find_by!(security: security, date: Date.current, currency: "USD")

    assert_equal BigDecimal("120"), holding.qty
    assert_equal BigDecimal("96.722"), holding.price
    assert_equal holding.price, snapshot.price
  end

  private
    def process_holding(overrides = {})
      @ibkr_account.update!(raw_holdings_payload: [ position_row(overrides) ])
      IbkrAccount::HoldingsProcessor.new(@ibkr_account).process
    end

    def position_row(overrides)
      {
        "asset_category" => "STK",
        "conid" => "265598",
        "security_id" => "US0378331005",
        "security_id_type" => "ISIN",
        "symbol" => @security.ticker,
        "position" => "10",
        "mark_price" => "150.00",
        "currency" => "USD",
        "fx_rate_to_base" => "0.90",
        "cost_basis_price" => "125.50",
        "report_date" => @report_date.to_s,
        "side" => "Long"
      }.merge(overrides)
    end
end
