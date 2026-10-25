require "test_helper"

class IbkrItem::ReportParserTest < ActiveSupport::TestCase
  XML_TEMPLATE = <<~XML
    <FlexQueryResponse>
      <FlexStatements>
        <FlexStatement accountId="U7654321" toDate="20260924">
          <AccountInformation accountId="U7654321" currency="HKD"/>
          <ChangeInPositionValues>
    %<rows>s
          </ChangeInPositionValues>
          <CashReports>
            <CashReport currency="BASE_SUMMARY" endingCash="200.00"/>
          </CashReports>
        </FlexStatement>
      </FlexStatements>
    </FlexQueryResponse>
  XML

  test "parse sums every BASE_SUMMARY ChangeInPositionValue row across asset categories" do
    # Stocks and bonds each emit their own BASE_SUMMARY row (plus per-currency
    # detail rows). Dropping all but the first row under-reports the balance by
    # every category after the first.
    rows = [
      '<ChangeInPositionValue currency="BASE_SUMMARY" endOfPeriodValue="1000.00"/>',
      '<ChangeInPositionValue currency="USD" endOfPeriodValue="128.20"/>',
      '<ChangeInPositionValue currency="BASE_SUMMARY" endOfPeriodValue="500.00"/>',
      '<ChangeInPositionValue currency="USD" endOfPeriodValue="64.10"/>'
    ].join("\n    ")

    account = IbkrItem::ReportParser.new(format(XML_TEMPLATE, rows: rows)).parse[:accounts].first

    assert_equal BigDecimal("1700.00"), account[:current_balance]
    assert_equal BigDecimal("200.00"), account[:cash_balance]
  end

  test "parse keeps single-category statement balance unchanged" do
    rows = '<ChangeInPositionValue currency="BASE_SUMMARY" endOfPeriodValue="1000.00"/>'

    account = IbkrItem::ReportParser.new(format(XML_TEMPLATE, rows: rows)).parse[:accounts].first

    assert_equal BigDecimal("1200.00"), account[:current_balance]
  end
end
