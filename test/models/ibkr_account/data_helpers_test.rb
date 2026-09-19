# frozen_string_literal: true

require "test_helper"

class IbkrAccount::DataHelpersTest < ActiveSupport::TestCase
  class TestHelper
    include IbkrAccount::DataHelpers

    public :parse_decimal
  end

  setup do
    @helper = TestHelper.new
  end

  test "parse_decimal returns nil for nil input" do
    assert_nil @helper.parse_decimal(nil)
  end

  test "parse_decimal returns nil for blank string" do
    assert_nil @helper.parse_decimal("")
    assert_nil @helper.parse_decimal("   ")
  end

  test "parse_decimal returns nil for dash placeholder" do
    assert_nil @helper.parse_decimal("-")
  end

  test "parse_decimal converts parentheses notation to negative" do
    assert_equal BigDecimal("-1234.56"), @helper.parse_decimal("(1234.56)")
  end

  test "parse_decimal converts parentheses notation with comma-separated number" do
    assert_equal BigDecimal("-1234.56"), @helper.parse_decimal("(1,234.56)")
  end

  test "parse_decimal strips commas from positive numbers" do
    assert_equal BigDecimal("1234.56"), @helper.parse_decimal("1,234.56")
  end

  test "parse_decimal parses plain decimal string" do
    assert_equal BigDecimal("3351.00"), @helper.parse_decimal("3351.00")
  end

  test "parse_decimal returns nil for empty parentheses" do
    assert_nil @helper.parse_decimal("()")
  end

  test "parse_decimal returns nil for unclosed parenthesis" do
    assert_nil @helper.parse_decimal("(123")
  end

  test "parse_decimal returns nil for non-numeric string" do
    assert_nil @helper.parse_decimal("N/A")
    assert_nil @helper.parse_decimal("not_a_number")
  end
end

# resolve_security's sibling lookup is scoped to the account's provider holdings,
# which needs PostgreSQL, so stub the candidate list and the Security lookups here.
class IbkrAccount::DataHelpersResolveSecurityTest < ActiveSupport::TestCase
  class SiblingHelper
    include IbkrAccount::DataHelpers

    attr_reader :account

    def initialize(provider_tickers, account: Object.new)
      @provider_tickers = provider_tickers
      @account = account
    end

    public :resolve_security, :security_from_provider_sibling, :unique_ticker_match, :ticker_key, :canonical_ticker

    private

      def provider_holding_tickers
        @provider_tickers
      end
  end

  setup do
    @helper = SiblingHelper.new([])
  end

  test "ticker_key ignores an exchange suffix" do
    assert_equal "EMAAR", @helper.ticker_key("EMAAR.XDFM")
    assert_equal "EMAAR", @helper.ticker_key("EMAAR")
  end

  test "ticker_key collapses Hong Kong zero padding" do
    assert_equal @helper.ticker_key("823.HK"), @helper.ticker_key("0823.HK")
  end

  test "ticker_key keeps different instruments apart" do
    refute_equal @helper.ticker_key("EMAAR"), @helper.ticker_key("EMAARX")
  end

  test "unique_ticker_match returns the single ticker sharing the normalized key" do
    assert_equal "EMAAR.XDFM", @helper.unique_ticker_match("EMAAR", [ "EMAAR.XDFM", "ENBD.DUBAI" ])
    assert_equal "823.HK", @helper.unique_ticker_match("0823.HK", [ "823.HK", "700.HK" ])
  end

  test "unique_ticker_match returns nil when no candidate matches" do
    assert_nil @helper.unique_ticker_match("EMAAR", [ "ENBD.DUBAI" ])
    assert_nil @helper.unique_ticker_match("EMAAR", [])
  end

  test "unique_ticker_match returns nil when two candidates are ambiguous" do
    assert_nil @helper.unique_ticker_match("EMAAR", [ "EMAAR.XDFM", "EMAAR.AE" ])
  end

  test "resolve_security reuses the provider-holding spelling instead of creating a second security" do
    helper = SiblingHelper.new([ "EMAAR.XDFM" ])
    looked_up = []
    sibling = Security.new(ticker: "EMAAR.XDFM")

    find_by = ->(*args, **kwargs) do
      ticker = kwargs[:ticker] || args.first[:ticker]
      looked_up << ticker
      ticker == "EMAAR" ? nil : sibling
    end

    Security.stub(:find_by, find_by) do
      assert_same sibling, helper.resolve_security({ "symbol" => "emaar" })
    end

    assert_equal [ "EMAAR", "EMAAR.XDFM" ], looked_up
  end

  test "resolve_security still finds an exact ticker without consulting siblings" do
    helper = SiblingHelper.new([ "EMAAR.XDFM" ])
    looked_up = []
    exact = Security.new(ticker: "EMAAR")

    find_by = ->(*args, **kwargs) do
      looked_up << (kwargs[:ticker] || args.first[:ticker])
      exact
    end

    Security.stub(:find_by, find_by) do
      assert_same exact, helper.resolve_security({ "symbol" => "EMAAR" })
    end

    assert_equal [ "EMAAR" ], looked_up
  end

  test "resolve_security creates a new security when the sibling match is ambiguous" do
    helper = SiblingHelper.new([ "EMAAR.XDFM", "EMAAR.AE" ])
    created = []

    Security.stub(:find_by, nil) do
      Security.stub(:create!, ->(*args, **kwargs) { attrs = kwargs.presence || args.first; created << attrs; attrs }) do
        assert_equal({ ticker: "EMAAR", name: "EMAAR" }, helper.resolve_security({ "symbol" => "EMAAR" }))
      end
    end

    assert_equal 1, created.size
  end
end

# canonical_ticker runs before the exact lookup, so a bare Flex symbol must
# exact-match the exchange-suffixed row Sure already stores.
class IbkrAccount::DataHelpersCanonicalTickerTest < ActiveSupport::TestCase
  class CanonicalHelper
    include IbkrAccount::DataHelpers

    public :resolve_security, :canonical_ticker

    private

      def provider_holding_tickers
        []
      end
  end

  setup do
    @helper = CanonicalHelper.new
  end

  test "canonical_ticker appends .HK for SEHK listings" do
    assert_equal "1211.HK", @helper.canonical_ticker("1211", "SEHK")
  end

  test "canonical_ticker keeps an already-suffixed HK ticker" do
    assert_equal "1211.HK", @helper.canonical_ticker("1211.HK", "SEHK")
  end

  test "canonical_ticker appends .XDFM for Dubai exchange variants" do
    %w[DFM XDFM NASDUBAI DUBAI].each do |exchange|
      assert_equal "EMAAR.XDFM", @helper.canonical_ticker("EMAAR", exchange), "exchange=#{exchange}"
    end
  end

  test "canonical_ticker keeps an already-suffixed XDFM ticker" do
    assert_equal "EMAAR.XDFM", @helper.canonical_ticker("EMAAR.XDFM", "XDFM")
  end

  test "canonical_ticker leaves the ticker alone for nil or unknown exchanges" do
    assert_equal "EMAAR", @helper.canonical_ticker("EMAAR", nil)
    assert_equal "EMAAR", @helper.canonical_ticker("EMAAR", "NASDAQ")
    assert_equal "1211", @helper.canonical_ticker("1211", "")
  end

  test "resolve_security canonicalizes before the exact lookup so the existing suffixed row wins" do
    looked_up = []
    existing = Security.new(ticker: "1211.HK")

    find_by = ->(*args, **kwargs) do
      ticker = kwargs[:ticker] || args.first[:ticker]
      looked_up << ticker
      ticker == "1211.HK" ? existing : nil
    end

    Security.stub(:find_by, find_by) do
      assert_same existing, @helper.resolve_security({ "symbol" => "1211", "listing_exchange" => "SEHK" })
    end

    assert_equal [ "1211.HK" ], looked_up
  end

  test "create_security_from_row names the security from the row description" do
    created = []

    Security.stub(:find_by, nil) do
      Security.stub(:create!, ->(*args, **kwargs) { attrs = kwargs.presence || args.first; created << attrs; attrs }) do
        @helper.resolve_security({ "symbol" => "EMAAR", "listing_exchange" => "XDFM", "description" => "EMAAR PROPERTIES PJSC" })
      end
    end

    assert_equal [ { ticker: "EMAAR.XDFM", name: "EMAAR PROPERTIES PJSC" } ], created
  end

  test "create_security_from_row falls back to the ticker when the description is missing" do
    created = []

    Security.stub(:find_by, nil) do
      Security.stub(:create!, ->(*args, **kwargs) { attrs = kwargs.presence || args.first; created << attrs; attrs }) do
        @helper.resolve_security({ "symbol" => "EMAAR" })
      end
    end

    assert_equal [ { ticker: "EMAAR", name: "EMAAR" } ], created
  end
end
