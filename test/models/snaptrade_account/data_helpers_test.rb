# frozen_string_literal: true

require "test_helper"

# resolve_security's sibling lookup is scoped to the account's provider holdings,
# which needs PostgreSQL, so stub the candidate list and the Security lookups here.
class SnaptradeAccount::DataHelpersResolveSecurityTest < ActiveSupport::TestCase
  class SiblingHelper
    include SnaptradeAccount::DataHelpers

    attr_reader :account

    def initialize(provider_tickers, account: Object.new)
      @provider_tickers = provider_tickers
      @account = account
    end

    public :resolve_security, :security_from_provider_sibling, :unique_ticker_match, :ticker_key

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
      assert_same sibling, helper.resolve_security("emaar", { "description" => "Emaar Properties" })
    end

    assert_equal [ "EMAAR", "EMAAR.XDFM" ], looked_up
  end

  test "resolve_security still finds an exact ticker without consulting siblings" do
    helper = SiblingHelper.new([ "EMAAR.XDFM" ])
    looked_up = []
    exact = Security.new(ticker: "EMAAR", name: "Emaar Properties")

    find_by = ->(*args, **kwargs) do
      looked_up << (kwargs[:ticker] || args.first[:ticker])
      exact
    end

    Security.stub(:find_by, find_by) do
      assert_same exact, helper.resolve_security("EMAAR", {})
    end

    assert_equal [ "EMAAR" ], looked_up
  end

  test "resolve_security creates a new security when the sibling match is ambiguous" do
    helper = SiblingHelper.new([ "EMAAR.XDFM", "EMAAR.AE" ])
    created = []

    Security.stub(:find_by, nil) do
      Security.stub(:create!, ->(*args, **kwargs) { attrs = kwargs.presence || args.first; created << attrs; attrs }) do
        helper.resolve_security("EMAAR", {})
      end
    end

    assert_equal 1, created.size
    assert_equal "EMAAR", created.first[:ticker]
  end
end
