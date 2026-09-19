require "test_helper"

class SnaptradeAccount::ActivitiesProcessorTest < ActiveSupport::TestCase
  include SecuritiesTestHelper

  setup do
    @family = families(:dylan_family)
    @snaptrade_item = snaptrade_items(:configured_item)
    @snaptrade_account = snaptrade_accounts(:fidelity_401k)

    # Create a linked Sure account for the SnapTrade account
    @account = @family.accounts.create!(
      name: "Test Investment",
      balance: 50000,
      cash_balance: 1000,
      currency: "USD",
      accountable: Investment.new
    )

    # Link the SnapTrade account to the Sure account
    @snaptrade_account.ensure_account_provider!(@account)
    @snaptrade_account.reload
  end

  test "processes buy trade activity" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_trade_activity(
        id: "trade_001",
        type: "BUY",
        symbol: "AAPL",
        units: 10,
        price: 150.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    # Verify a trade was created (external_id is on entry, not trade)
    entry = @account.entries.find_by(external_id: "trade_001", source: "snaptrade")
    assert_not_nil entry, "Entry should be created"
    assert entry.entryable.is_a?(Trade), "Entry should be a Trade"

    trade = entry.entryable
    assert_equal 10, trade.qty
    assert_equal 150.00, trade.price.to_f
    assert_equal "Buy", trade.investment_activity_label
  end

  test "processes sell trade activity with negative quantity" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_trade_activity(
        id: "trade_002",
        type: "SELL",
        symbol: "AAPL",
        units: 5,
        price: 160.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "trade_002", source: "snaptrade")
    assert_not_nil entry
    trade = entry.entryable
    assert_equal(-5, trade.qty)  # Sell should be negative
    assert_equal "Sell", trade.investment_activity_label
  end

  test "processes dividend cash activity as negative inflow" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "div_001",
        type: "DIVIDEND",
        amount: 25.50,
        settlement_date: Date.current.to_s,
        symbol: "VTI"
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "div_001", source: "snaptrade")
    assert_not_nil entry, "Entry should be created"
    assert entry.entryable.is_a?(Transaction), "Entry should be a Transaction"

    transaction = entry.entryable
    assert_equal(-25.50, entry.amount.to_f)
    assert_equal "Dividend", transaction.investment_activity_label
  end

  test "processes contribution with negative inflow amount" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "contrib_001",
        type: "CONTRIBUTION",
        amount: 500.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "contrib_001", source: "snaptrade")
    assert_not_nil entry
    assert_equal(-500.00, entry.amount.to_f)
    assert_equal "Contribution", entry.entryable.investment_activity_label
  end

  test "processes withdrawal with positive outflow amount" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "withdraw_001",
        type: "WITHDRAWAL",
        amount: 200.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "withdraw_001", source: "snaptrade")
    assert_not_nil entry
    assert_equal 200.00, entry.amount.to_f
    assert_equal "Withdrawal", entry.entryable.investment_activity_label
  end

  test "processes transfers with Sure sign convention" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "transfer_in_001",
        type: "TRANSFER_IN",
        amount: 300.00,
        settlement_date: Date.current.to_s
      ),
      build_cash_activity(
        id: "transfer_out_001",
        type: "TRANSFER_OUT",
        amount: 125.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    transfer_in = @account.entries.find_by(external_id: "transfer_in_001", source: "snaptrade")
    transfer_out = @account.entries.find_by(external_id: "transfer_out_001", source: "snaptrade")

    assert_not_nil transfer_in
    assert_not_nil transfer_out
    assert_equal(-300.00, transfer_in.amount.to_f)
    assert_equal 125.00, transfer_out.amount.to_f
    assert_equal "Transfer", transfer_in.entryable.investment_activity_label
    assert_equal "Transfer", transfer_out.entryable.investment_activity_label
  end

  test "normalizes bare TRANSFER from the provider sign" do
    # Regression test for issue #2756. Unlike TRANSFER_IN/TRANSFER_OUT, a bare "TRANSFER"
    # carries no direction in the type, so SnapTrade's sign is the only directional signal
    # available and must be inverted into Sure's convention rather than passed through.
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "transfer_generic_in",
        type: "TRANSFER",
        amount: 1320.75,
        settlement_date: Date.current.to_s
      ),
      build_cash_activity(
        id: "transfer_generic_out",
        type: "TRANSFER",
        amount: -500.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    inbound = @account.entries.find_by(external_id: "transfer_generic_in", source: "snaptrade")
    outbound = @account.entries.find_by(external_id: "transfer_generic_out", source: "snaptrade")

    assert_not_nil inbound
    assert_not_nil outbound
    assert_equal(-1320.75, inbound.amount.to_f, "money in must be stored negative on an asset account")
    assert_equal 500.00, outbound.amount.to_f, "money out must be stored positive on an asset account"
  end

  test "processes debit interest narrative as expense despite INTEREST type" do
    # Regression test: IBKR reports margin interest PAID as type INTEREST with a
    # "DEBIT INT" narrative. The type map forces INTEREST to money-in, so the
    # narrative keyword must win.
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "int_debit_001",
        type: "INTEREST",
        amount: 6.08,
        settlement_date: Date.current.to_s,
        description: "USD DEBIT INT FOR JUN-2026"
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "int_debit_001", source: "snaptrade")
    assert_not_nil entry
    assert_equal 6.08, entry.amount.to_f, "debit interest is money out and must be stored positive"
    assert_equal "expense", entry.classification
    assert_equal "Interest", entry.entryable.investment_activity_label
  end

  test "processes credit interest narrative as income" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "int_credit_001",
        type: "INTEREST",
        amount: 0.69,
        settlement_date: Date.current.to_s,
        description: "USD CREDIT INT FOR JUN-2026"
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "int_credit_001", source: "snaptrade")
    assert_not_nil entry
    assert_equal(-0.69, entry.amount.to_f, "credit interest is money in and must be stored negative")
    assert_equal "income", entry.classification
  end

  test "processes inbound ACH credit narrative as income even when provider sign disagrees" do
    # Regression test: Citi inbound "ACH ELECTRONIC CREDIT" was observed syncing
    # as an expense. The narrative keyword must win over both the type map and
    # the provider-supplied sign.
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "ach_credit_001",
        type: "TRANSFER",
        amount: -250.00,
        settlement_date: Date.current.to_s,
        description: "ACH ELECTRONIC CREDIT and INTERACTIVE BROK ACH TRANSF"
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "ach_credit_001", source: "snaptrade")
    assert_not_nil entry
    assert_equal(-250.00, entry.amount.to_f, "inbound ACH credit is money in and must be stored negative")
    assert_equal "income", entry.classification
  end

  test "processes bank interest credit with DIVIDEND_AND_INTEREST type as income" do
    # Regression test: Citi "Interest Payment" arrives as DIVIDEND_AND_INTEREST
    # with a positive (account-perspective) amount. Before the type was added to
    # the money-in branch it hit the passthrough and stored as an expense.
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "int_payment_001",
        type: "DIVIDEND_AND_INTEREST",
        amount: 86.79,
        settlement_date: Date.current.to_s,
        description: "Interest Payment"
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "int_payment_001", source: "snaptrade")
    assert_not_nil entry
    assert_equal(-86.79, entry.amount.to_f, "bank interest received is money in and must be stored negative")
    assert_equal "income", entry.classification
  end

  test "processes bank interest adjustment / reward with DIVIDEND_AND_INTEREST type as income" do
    # Regression test: Citi "Interest Adj and Q1 26 INBTA Checking Reward".
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "int_adj_001",
        type: "DIVIDEND_AND_INTEREST",
        amount: 750.00,
        settlement_date: Date.current.to_s,
        description: "Interest Adj and Q1 26 INBTA Checking Reward"
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "int_adj_001", source: "snaptrade")
    assert_not_nil entry
    assert_equal(-750.00, entry.amount.to_f, "interest adjustment/reward is money in and must be stored negative")
    assert_equal "income", entry.classification
  end

  test "processes outbound ACH debit narrative as expense" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "ach_debit_001",
        type: "TRANSFER",
        amount: 250.00,
        settlement_date: Date.current.to_s,
        description: "ACH ELECTRONIC DEBIT and INTERACTIVE BROK ACH TRANSF"
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "ach_debit_001", source: "snaptrade")
    assert_not_nil entry
    assert_equal 250.00, entry.amount.to_f, "outbound ACH debit is money out and must be stored positive"
    assert_equal "expense", entry.classification
  end

  test "maps all known activity types correctly" do
    type_mappings = {
      "BUY" => "Buy",
      "SELL" => "Sell",
      "DIVIDEND" => "Dividend",
      "DIV" => "Dividend",
      "CONTRIBUTION" => "Contribution",
      "WITHDRAWAL" => "Withdrawal",
      "TRANSFER_IN" => "Transfer",
      "TRANSFER_OUT" => "Transfer",
      "INTEREST" => "Interest",
      "FEE" => "Fee",
      "TAX" => "Fee",
      "REI" => "Reinvestment",
      "REINVEST" => "Reinvestment",
      "CASH" => "Contribution",
      "CORP_ACTION" => "Other",
      "SPLIT_REVERSE" => "Other"
    }

    type_mappings.each do |snaptrade_type, expected_label|
      actual = SnaptradeAccount::ActivitiesProcessor::SNAPTRADE_TYPE_TO_LABEL[snaptrade_type]
      assert_equal expected_label, actual, "Type #{snaptrade_type} should map to #{expected_label}"
    end
  end

  test "logs unmapped activity types" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "unknown_001",
        type: "SOME_NEW_TYPE",
        amount: 100.00,
        settlement_date: Date.current.to_s
      )
    ])

    # Capture log output
    log_output = StringIO.new
    old_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    Rails.logger = old_logger

    assert_includes log_output.string, "Unmapped activity type 'SOME_NEW_TYPE'"
  end

  test "skips activities without external_id" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: nil,
        type: "DIVIDEND",
        amount: 50.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    # No entry should be created with snaptrade source
    assert_equal 0, @account.entries.where(source: "snaptrade").count
  end

  test "skips processing when no linked account" do
    # Remove the account provider link
    @snaptrade_account.account_provider&.destroy
    @snaptrade_account.reload

    @snaptrade_account.update!(raw_activities_payload: [
      build_trade_activity(
        id: "trade_orphan",
        type: "BUY",
        symbol: "AAPL",
        units: 10,
        price: 150.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    # No entries should be created with this external_id
    assert_equal 0, Entry.where(external_id: "trade_orphan").count
  end

  test "processor reuses this account's provider security when SnapTrade spells a ticker differently" do
    # The holdings feed reports the exchange-suffixed spelling, the activities feed
    # the bare one. Before the fix the bare symbol missed the exact match and created
    # a second Security, splitting the holding from its trades.
    suffixed = Security.create!(ticker: "EMAAR.XDFM", name: "Emaar Properties PJSC")

    @account.holdings.create!(
      security: suffixed,
      date: Date.current,
      qty: BigDecimal("12610"),
      price: BigDecimal("2.00"),
      amount: BigDecimal("25220.00"),
      currency: "AED",
      external_id: "snaptrade_holding_emaar",
      account_provider_id: @snaptrade_account.account_provider&.id
    )

    @snaptrade_account.update!(raw_activities_payload: [
      build_trade_activity(
        id: "trade_emaar_001",
        type: "BUY",
        symbol: "EMAAR",
        units: 100,
        price: 2.00,
        settlement_date: Date.current.to_s
      )
    ])

    SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account).process

    assert_nil Security.find_by(ticker: "EMAAR"), "expected no duplicate bare-ticker Security"
    entry = @account.entries.find_by(external_id: "trade_emaar_001")
    assert_not_nil entry
    assert_equal suffixed.id, entry.entryable.security_id
  end

  private

    def build_trade_activity(id:, type:, symbol:, units:, price:, settlement_date:)
      {
        "id" => id,
        "type" => type,
        "symbol" => {
          "symbol" => symbol,
          "description" => "#{symbol} Inc"
        },
        "units" => units,
        "price" => price,
        "settlement_date" => settlement_date,
        "currency" => { "code" => "USD" }
      }
    end

    def build_cash_activity(id:, type:, amount:, settlement_date:, symbol: nil, description: nil)
      activity = {
        "id" => id,
        "type" => type,
        "amount" => amount,
        "settlement_date" => settlement_date,
        "currency" => { "code" => "USD" }
      }

      activity["description"] = description if description

      if symbol
        activity["symbol"] = {
          "symbol" => symbol,
          "description" => "#{symbol} Fund"
        }
      end

      activity
    end
end
