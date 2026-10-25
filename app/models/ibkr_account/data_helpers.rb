module IbkrAccount::DataHelpers
  extend ActiveSupport::Concern

  private

    def parse_decimal(value)
      return nil if value.nil?

      normalized = value.is_a?(String) ? value.delete(",").strip : value.to_s
      return nil if normalized.blank? || normalized == "-"

      # Convert accounting parentheses notation: "(1234.56)" → "-1234.56"
      normalized = "-#{normalized[1..-2]}" if normalized.start_with?("(") && normalized.end_with?(")")

      BigDecimal(normalized)
    rescue ArgumentError
      nil
    end

    def parse_date(value)
      return nil if value.blank?

      case value
      when Date
        value
      when Time, DateTime, ActiveSupport::TimeWithZone
        value.to_date
      else
        normalized = value.to_s.tr(";", " ")
        Time.zone.parse(normalized)&.to_date || Date.parse(normalized)
      end
    rescue ArgumentError, TypeError
      nil
    end

    def parse_datetime(value)
      return nil if value.blank?

      case value
      when Time, DateTime, ActiveSupport::TimeWithZone
        value.in_time_zone
      when Date
        value.in_time_zone
      else
        Time.zone.parse(value.to_s.tr(";", " "))
      end
    rescue ArgumentError, TypeError
      nil
    end

    def resolve_security(row)
      data = row.with_indifferent_access
      ticker = data[:symbol].to_s.strip.upcase
      return nil if ticker.blank?

      ticker = canonical_ticker(ticker, data[:listing_exchange])

      Security.find_by(ticker: ticker) || security_from_provider_sibling(ticker) || create_security_from_row(ticker, data)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: ticker)
    end

    # IBKR Flex spells exchange-listed symbols bare ("EMAAR", "1211") while Sure
    # stores the exchange-suffixed spelling ("EMAAR.XDFM", "1211.HK"). Creating a
    # bare row duplicates the existing security and goes unpriced by Yahoo, so
    # canonicalize before any lookup. No zero-padding on SEHK: existing rows are
    # spelled "823.HK", not "0823.HK".
    # ponytail: the DFM listing_exchange value set is defensive — the exact Flex
    # value is unconfirmed; verify and edit this one line if IBKR reports another.
    def canonical_ticker(ticker, listing_exchange)
      case listing_exchange.to_s.strip.upcase
      when "SEHK"
        ticker.end_with?(".HK") ? ticker : "#{ticker}.HK"
      when "DFM", "XDFM", "NASDUBAI", "DUBAI"
        ticker.end_with?(".XDFM") ? ticker : "#{ticker}.XDFM"
      else
        ticker
      end
    end

    # Two IBKR feeds can spell one instrument differently (positions "EMAAR.XDFM",
    # activities "EMAAR"). The exact match misses, so we used to create a second
    # Security and split the holding and its trades across two rows — permanent,
    # since Sure has no security merge. When this account already syncs a security
    # whose ticker normalizes to the same key, reuse that spelling instead.
    # No match, or more than one candidate → nil, i.e. today's behaviour.
    #
    # Ticker-level on purpose: upstream's MIC canonicalization (PR #3141) matches
    # cases of the same MIC and cannot see that "EMAAR.XDFM" and "EMAAR" are one
    # instrument, and this branch's base (v0.7.3) predates it.
    def security_from_provider_sibling(ticker)
      sibling = unique_ticker_match(ticker, provider_holding_tickers)
      sibling && Security.find_by(ticker: sibling)
    end

    # Tickers this account already holds via a provider sync. Manual holdings carry
    # no external_id/account_provider_id, so they are excluded on purpose: only a
    # provider spelling is authoritative for a provider feed. Includers supply #account.
    def provider_holding_tickers
      return [] unless account

      Holding.where(account_id: account.id)
        .where("holdings.external_id IS NOT NULL OR holdings.account_provider_id IS NOT NULL")
        .joins(:security)
        .distinct
        .pluck("securities.ticker")
    end

    # Returns the one candidate ticker sharing +ticker+'s normalized key, else nil.
    def unique_ticker_match(ticker, candidates)
      key = ticker_key(ticker)
      matches = candidates.select { |candidate| ticker_key(candidate) == key }
      matches.one? ? matches.first : nil
    end

    # Strips an exchange suffix ("EMAAR.XDFM" → "EMAAR") and HK-style zero padding
    # ("0823.HK" → "823"). Blunt on purpose: callers only consult it when the exact
    # ticker is missing and require a single provider-backed sibling, so an over-eager
    # collapse cannot invent a row — it can only reuse one this account already syncs.
    def ticker_key(ticker)
      base = ticker.to_s.strip.upcase.sub(/\.[A-Z0-9]{1,4}\z/, "")
      base.sub(/\A0+(?=\d)/, "")
    end

    def trade_date_for(row)
      data = row.with_indifferent_access
      parsed_trade_date = parse_date(data[:trade_date])
      return parsed_trade_date if parsed_trade_date

      Rails.logger.warn(
        "IbkrAccount::DataHelpers - Missing or invalid trade_date, falling back to Date.current. " \
        "trade_id=#{data[:trade_id].inspect}"
      )
      Date.current
    end

    def extract_currency(row, fallback: nil)
      value = row.with_indifferent_access[:currency]
      value.present? ? value.to_s.upcase : fallback
    end

    # IBKR Flex reports bond quantities as face value (position/trade quantity
    # 12000) while prices stay percent-of-par (markPrice/tradePrice 96.722).
    # Store quantity as face/100 so amount = qty × price and the per-unit cost
    # basis stays percent-of-par (valid_lots weights by the converted qty).
    def normalized_quantity(row, quantity)
      row[:asset_category].to_s == "BOND" ? quantity / 100 : quantity
    end

    def create_security_from_row(ticker, data)
      Security.create!(ticker: ticker, name: data[:description].presence || ticker)
    end
end
