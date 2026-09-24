require "test_helper"

class IbkrAccountProcessorTest < ActiveSupport::TestCase
  fixtures :families, :ibkr_items, :ibkr_accounts, :accounts, :securities

  setup do
    @family = families(:dylan_family)
    @ibkr_account = ibkr_accounts(:main_account)

    @account = @family.accounts.create!(
      name: "IBKR Investment",
      balance: 0,
      cash_balance: 0,
      currency: "CHF",
      accountable: Investment.new(subtype: "brokerage")
    )
    @ibkr_account.ensure_account_provider!(@account)
    @ibkr_account.update!(
      raw_holdings_payload: [
        {
          "asset_category" => "STK",
          "conid" => "265598",
          "security_id" => "US0378331005",
          "security_id_type" => "ISIN",
          "symbol" => securities(:aapl).ticker,
          "position" => "10",
          "mark_price" => "150.00",
          "currency" => "USD",
          "fx_rate_to_base" => "0.90",
          "cost_basis_price" => "125.50",
          "report_date" => Date.current.to_s,
          "side" => "Long"
        }
      ],
      raw_activities_payload: {
        trades: [
          {
            "asset_category" => "STK",
            "trade_id" => "1001",
            "transaction_id" => "1001a",
            "conid" => "265598",
            "symbol" => securities(:aapl).ticker,
            "quantity" => "2",
            "trade_price" => "140.00",
            "currency" => "USD",
            "fx_rate_to_base" => "0.90",
            "buy_sell" => "BUY",
            "trade_date" => Date.current.to_s,
            "ib_commission" => "-1.25",
            "ib_commission_currency" => "USD"
          },
          {
            "asset_category" => "STK",
            "trade_id" => "1002",
            "transaction_id" => "1002a",
            "conid" => "265598",
            "symbol" => securities(:aapl).ticker,
            "quantity" => "-1",
            "trade_price" => "155.00",
            "currency" => "USD",
            "fx_rate_to_base" => "0.92",
            "buy_sell" => "SELL",
            "trade_date" => Date.current.to_s,
            "ib_commission" => "-1.10",
            "ib_commission_currency" => "USD"
          }
        ],
        cash_transactions: [
          {
            "transaction_id" => "4001",
            "type" => "Deposits/Withdrawals",
            "amount" => "500.00",
            "currency" => "CHF",
            "fx_rate_to_base" => "1",
            "report_date" => Date.current.to_s
          },
          {
            "transaction_id" => "4002",
            "type" => "Dividends",
            "amount" => "2.50",
            "currency" => "USD",
            "fx_rate_to_base" => "0.91",
            "report_date" => Date.current.to_s,
            "conid" => "265598"
          }
        ]
      },
      report_date: Date.current,
      current_balance: BigDecimal("3351.00"),
      cash_balance: BigDecimal("1000.50"),
      currency: "CHF"
    )
  end

  test "processor imports holdings, trades, cash transactions, and commissions" do
    IbkrAccount::Processor.new(@ibkr_account).process

    @account.reload
    assert_equal BigDecimal("3351.00"), @account.balance
    assert_equal BigDecimal("1000.50"), @account.cash_balance
    assert_equal "CHF", @account.currency

    holding = @account.holdings.find_by(security: securities(:aapl), date: Date.current)
    assert_not_nil holding
    assert_equal BigDecimal("10"), holding.qty
    assert_equal BigDecimal("150.00"), holding.price
    assert_equal BigDecimal("125.50"), holding.cost_basis
    assert_equal "USD", holding.currency

    buy_trade = @account.entries.find_by(external_id: "ibkr_trade_1001")
    sell_trade = @account.entries.find_by(external_id: "ibkr_trade_1002")
    assert_not_nil buy_trade
    assert_not_nil sell_trade
    assert_equal "Buy", buy_trade.entryable.investment_activity_label
    assert_equal "Sell", sell_trade.entryable.investment_activity_label
    assert_equal BigDecimal("2"), buy_trade.entryable.qty
    assert_equal BigDecimal("-1"), sell_trade.entryable.qty
    assert_equal BigDecimal("280.0"), buy_trade.amount
    assert_equal BigDecimal("-155.0"), sell_trade.amount
    assert_equal "USD", buy_trade.currency
    assert_equal "USD", sell_trade.currency
    assert_equal 0.9, buy_trade.entryable.exchange_rate
    assert_equal 0.92, sell_trade.entryable.exchange_rate

    dividend = @account.entries.find_by(external_id: "ibkr_cash_4002")
    assert_not_nil dividend
    assert_equal "Dividend", dividend.entryable.investment_activity_label
    assert_equal BigDecimal("-2.5"), dividend.amount
    assert_equal securities(:aapl).id, dividend.entryable.extra["security_id"]

    commission_one = @account.entries.find_by(external_id: "ibkr_trade_fee_1001")
    commission_two = @account.entries.find_by(external_id: "ibkr_trade_fee_1002")
    assert_not_nil commission_one
    assert_not_nil commission_two
    assert_equal BigDecimal("1.25"), commission_one.amount
    assert_equal BigDecimal("1.1"), commission_two.amount
    assert_equal "USD", commission_one.currency
    assert_equal "USD", commission_two.currency
    assert_equal securities(:aapl).id, commission_one.entryable.extra["security_id"]
    assert_equal securities(:aapl).id, commission_two.entryable.extra["security_id"]

    deposit = @account.entries.find_by(external_id: "ibkr_cash_4001")

    assert_not_nil deposit
    assert_equal "Contribution", deposit.entryable.investment_activity_label
    assert_equal BigDecimal("-500"), deposit.amount
    assert_equal "CHF", deposit.currency

    assert_equal "USD", dividend.currency
  end

  test "processor computes weighted provider cost basis for grouped lots" do
    @ibkr_account.update!(
      raw_holdings_payload: [
        {
          "asset_category" => "STK",
          "conid" => "265598",
          "security_id" => "US0378331005",
          "security_id_type" => "ISIN",
          "symbol" => securities(:aapl).ticker,
          "position" => "10",
          "mark_price" => "150.00",
          "currency" => "USD",
          "fx_rate_to_base" => "0.90",
          "cost_basis_price" => "125.50",
          "report_date" => Date.current.to_s,
          "side" => "Long"
        },
        {
          "asset_category" => "STK",
          "conid" => "265598",
          "security_id" => "US0378331005",
          "security_id_type" => "ISIN",
          "symbol" => securities(:aapl).ticker,
          "position" => "20",
          "mark_price" => "150.00",
          "currency" => "USD",
          "fx_rate_to_base" => "0.90",
          "cost_basis_price" => "122.00",
          "report_date" => Date.current.to_s,
          "side" => "Long"
        }
      ]
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    holding = @account.holdings.find_by(security: securities(:aapl), date: Date.current)

    assert_not_nil holding
    assert_equal BigDecimal("30"), holding.qty
    assert_in_delta BigDecimal("123.1667"), holding.cost_basis, BigDecimal("0.0001")
  end

  test "processor repairs default opening anchor after importing activity entries" do
    result = Account::OpeningBalanceManager.new(@account).set_opening_balance(
      balance: @ibkr_account.current_balance,
      date: 2.years.ago.to_date
    )

    assert result.success?

    opening_anchor = @account.valuations.opening_anchor.includes(:entry).first
    assert_not_nil opening_anchor
    assert_equal @ibkr_account.current_balance.to_d, opening_anchor.entry.amount.to_d

    IbkrAccount::Processor.new(@ibkr_account).process

    opening_anchor.reload
    assert_equal BigDecimal("0"), opening_anchor.entry.amount.to_d
  end

  test "processor imports commission-free trades without creating fee entries" do
    @ibkr_account.update!(
      raw_activities_payload: {
        trades: [
          {
            "asset_category" => "STK",
            "trade_id" => "1003",
            "transaction_id" => "1003a",
            "conid" => "265598",
            "symbol" => securities(:aapl).ticker,
            "quantity" => "3",
            "trade_price" => "145.00",
            "currency" => "USD",
            "fx_rate_to_base" => "0.91",
            "buy_sell" => "BUY",
            "trade_date" => Date.current.to_s
          }
        ],
        cash_transactions: []
      }
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    trade = @account.entries.find_by(external_id: "ibkr_trade_1003")
    fee = @account.entries.find_by(external_id: "ibkr_trade_fee_1003")

    assert_not_nil trade
    assert_equal BigDecimal("3"), trade.entryable.qty
    assert_equal BigDecimal("435.0"), trade.amount
    assert_equal "USD", trade.currency
    assert_nil fee
  end

  test "processor logs and falls back to current date for invalid trade_date" do
    @ibkr_account.update!(
      raw_activities_payload: {
        trades: [
          {
            "asset_category" => "STK",
            "trade_id" => "1004",
            "transaction_id" => "1004a",
            "conid" => "265598",
            "symbol" => securities(:aapl).ticker,
            "quantity" => "1",
            "trade_price" => "146.00",
            "currency" => "USD",
            "fx_rate_to_base" => "0.91",
            "buy_sell" => "BUY",
            "trade_date" => "not-a-date"
          }
        ],
        cash_transactions: []
      }
    )

    Rails.logger.expects(:warn).with do |message|
      message.include?("IbkrAccount::DataHelpers - Missing or invalid trade_date") &&
        message.include?("1004")
    end

    IbkrAccount::Processor.new(@ibkr_account).process

    trade = @account.entries.find_by(external_id: "ibkr_trade_1004")

    assert_not_nil trade
    assert_equal Date.current, trade.date
  end

  test "processor imports bond holdings converting face value to per-100 quantity" do
    # IBKR Flex reports bond position as face value and mark/cost prices as
    # percent of par. Convention: qty = face/100, price stays percent-of-par,
    # so amount = qty × price matches IBKR's positionValue exactly
    # (12000 × 96.722/100 = 11606.64).
    @ibkr_account.update!(
      raw_holdings_payload: [
        {
          "asset_category" => "BOND",
          "conid" => "999001",
          "security_id" => "US912810TD00",
          "security_id_type" => "ISIN",
          "symbol" => "TESTBOND",
          "position" => "12000",
          "mark_price" => "96.722",
          "currency" => "USD",
          "fx_rate_to_base" => "1",
          "cost_basis_price" => "96.722",
          "report_date" => Date.current.to_s,
          "side" => "Long"
        }
      ]
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    holding = @account.holdings.find_by(security: Security.find_by!(ticker: "TESTBOND"), date: Date.current)
    assert_not_nil holding
    assert_equal BigDecimal("120"), holding.qty
    assert_equal BigDecimal("96.722"), holding.price
    assert_equal BigDecimal("11606.64"), holding.amount
    assert_equal BigDecimal("96.722"), holding.cost_basis
    assert_equal "USD", holding.currency
  end

  test "processor computes weighted bond cost basis across grouped lots in per-100 units" do
    @ibkr_account.update!(
      raw_holdings_payload: [
        {
          "asset_category" => "BOND",
          "conid" => "999001",
          "security_id" => "US912810TD00",
          "security_id_type" => "ISIN",
          "symbol" => "TESTBOND",
          "position" => "12000",
          "mark_price" => "96.722",
          "currency" => "USD",
          "fx_rate_to_base" => "1",
          "cost_basis_price" => "96.722",
          "report_date" => Date.current.to_s,
          "side" => "Long"
        },
        {
          "asset_category" => "BOND",
          "conid" => "999001",
          "security_id" => "US912810TD00",
          "security_id_type" => "ISIN",
          "symbol" => "TESTBOND",
          "position" => "8000",
          "mark_price" => "96.722",
          "currency" => "USD",
          "fx_rate_to_base" => "1",
          "cost_basis_price" => "98.00",
          "report_date" => Date.current.to_s,
          "side" => "Long"
        }
      ]
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    holding = @account.holdings.find_by(security: Security.find_by!(ticker: "TESTBOND"), date: Date.current)
    assert_not_nil holding
    assert_equal BigDecimal("200"), holding.qty
    # (120 × 96.722 + 80 × 98.00) / 200 = 97.2332
    assert_in_delta BigDecimal("97.2332"), holding.cost_basis, BigDecimal("0.0001")
  end

  test "processor handles government-style bond tickers and never merges same-issuer bonds" do
    # Treasury-style symbols carry spaces and a slash, and one issuer can have
    # several coupon/maturity lines. Each conid+symbol pair must resolve to its
    # own Security and its own holding — never merged into one row.
    @ibkr_account.update!(
      raw_holdings_payload: [
        bond_holding_row(conid: "555001", symbol: "T 4.5 08/15/33", position: "5000", cost_basis_price: "97.10"),
        bond_holding_row(conid: "555002", symbol: "ACME 5.0 01/15/30", position: "10000", cost_basis_price: "99.00"),
        bond_holding_row(conid: "555003", symbol: "ACME 5.5 03/01/31", position: "6000", cost_basis_price: "101.25")
      ]
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    treasury = Security.find_by!(ticker: "T 4.5 08/15/33")
    acme_50 = Security.find_by!(ticker: "ACME 5.0 01/15/30")
    acme_55 = Security.find_by!(ticker: "ACME 5.5 03/01/31")
    assert_equal 3, [ treasury, acme_50, acme_55 ].map(&:id).uniq.size

    treasury_holding = @account.holdings.find_by!(security: treasury, date: Date.current)
    assert_equal BigDecimal("50"), treasury_holding.qty
    assert_equal BigDecimal("97.10"), treasury_holding.cost_basis

    acme_50_holding = @account.holdings.find_by!(security: acme_50, date: Date.current)
    assert_equal BigDecimal("100"), acme_50_holding.qty
    assert_equal BigDecimal("99.00"), acme_50_holding.cost_basis

    acme_55_holding = @account.holdings.find_by!(security: acme_55, date: Date.current)
    assert_equal BigDecimal("60"), acme_55_holding.qty
    assert_equal BigDecimal("101.25"), acme_55_holding.cost_basis
  end

  test "processor imports bond trades converting face value to per-100 quantity" do
    @ibkr_account.update!(
      raw_activities_payload: {
        trades: [
          {
            "asset_category" => "BOND",
            "trade_id" => "8001",
            "transaction_id" => "8001a",
            "conid" => "999001",
            "symbol" => "TESTBOND",
            "quantity" => "5000",
            "trade_price" => "98.5",
            "currency" => "USD",
            "fx_rate_to_base" => "1",
            "buy_sell" => "BUY",
            "trade_date" => Date.current.to_s
          },
          {
            "asset_category" => "BOND",
            "trade_id" => "8002",
            "transaction_id" => "8002a",
            "conid" => "999001",
            "symbol" => "TESTBOND",
            "quantity" => "3000",
            "trade_price" => "99.0",
            "currency" => "USD",
            "fx_rate_to_base" => "1",
            "buy_sell" => "SELL",
            "trade_date" => Date.current.to_s
          }
        ],
        cash_transactions: []
      }
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    buy_trade = @account.entries.find_by(external_id: "ibkr_trade_8001")
    sell_trade = @account.entries.find_by(external_id: "ibkr_trade_8002")
    assert_not_nil buy_trade
    assert_not_nil sell_trade

    assert_equal BigDecimal("50"), buy_trade.entryable.qty
    assert_equal BigDecimal("98.5"), buy_trade.entryable.price
    assert_equal BigDecimal("4925.0"), buy_trade.amount
    assert_equal "Buy", buy_trade.entryable.investment_activity_label

    assert_equal BigDecimal("-30"), sell_trade.entryable.qty
    assert_equal BigDecimal("-2970.0"), sell_trade.amount
    assert_equal "Sell", sell_trade.entryable.investment_activity_label
  end

  test "processor still skips non-STK non-BOND asset categories" do
    @ibkr_account.update!(
      raw_holdings_payload: [
        {
          "asset_category" => "OPT",
          "conid" => "999002",
          "security_id" => "US0378331005",
          "security_id_type" => "ISIN",
          "symbol" => "TESTOPT",
          "position" => "10",
          "mark_price" => "1.00",
          "currency" => "USD",
          "fx_rate_to_base" => "1",
          "cost_basis_price" => "1.00",
          "report_date" => Date.current.to_s,
          "side" => "Long"
        }
      ],
      raw_activities_payload: {
        trades: [
          {
            "asset_category" => "OPT",
            "trade_id" => "8003",
            "transaction_id" => "8003a",
            "conid" => "999002",
            "symbol" => "TESTOPT",
            "quantity" => "10",
            "trade_price" => "1.00",
            "currency" => "USD",
            "fx_rate_to_base" => "1",
            "buy_sell" => "BUY",
            "trade_date" => Date.current.to_s
          }
        ],
        cash_transactions: []
      }
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    assert_nil Security.find_by(ticker: "TESTOPT")
    assert_equal 0, @account.holdings.count
    assert_nil @account.entries.find_by(external_id: "ibkr_trade_8003")
  end

  test "processor reuses this account's provider security when IBKR spells a ticker differently" do
    # The positions feed reports the exchange-suffixed spelling, the activities feed
    # the bare one. Before the fix the bare symbol missed the exact match and created
    # a second Security, splitting the holding from its trades.
    suffixed = Security.create!(ticker: "EMAAR.XDFM", name: "EMAAR PROPERTIES PJSC")

    @account.holdings.create!(
      security: suffixed,
      date: Date.current,
      qty: BigDecimal("12610"),
      price: BigDecimal("2.00"),
      amount: BigDecimal("25220.00"),
      currency: "AED",
      external_id: "ibkr_#{@ibkr_account.ibkr_account_id}_665212_#{Date.current}_AED",
      account_provider_id: @ibkr_account.account_provider&.id
    )

    @ibkr_account.update!(
      raw_activities_payload: {
        trades: [
          {
            "asset_category" => "STK",
            "trade_id" => "9001",
            "transaction_id" => "9001a",
            "conid" => "665212",
            "symbol" => "EMAAR",
            "quantity" => "100",
            "trade_price" => "2.00",
            "currency" => "AED",
            "fx_rate_to_base" => "1",
            "buy_sell" => "BUY",
            "trade_date" => Date.current.to_s
          }
        ],
        cash_transactions: []
      }
    )

    IbkrAccount::Processor.new(@ibkr_account).process

    assert_nil Security.find_by(ticker: "EMAAR"), "expected no duplicate bare-ticker Security"
    trade = @account.entries.find_by(external_id: "ibkr_trade_9001")
    assert_not_nil trade
    assert_equal suffixed.id, trade.entryable.security_id
  end

  private

    def bond_holding_row(conid:, symbol:, position:, cost_basis_price:)
      {
        "asset_category" => "BOND",
        "conid" => conid,
        "security_id" => "US#{conid}BOND",
        "security_id_type" => "ISIN",
        "symbol" => symbol,
        "position" => position,
        "mark_price" => cost_basis_price,
        "currency" => "USD",
        "fx_rate_to_base" => "1",
        "cost_basis_price" => cost_basis_price,
        "report_date" => Date.current.to_s,
        "side" => "Long"
      }
    end
end
