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

      Security.find_by(ticker: ticker) || security_from_provider_sibling(ticker) || create_security_from_row(ticker)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: ticker)
    end

    # Two IBKR feeds can spell one instrument differently (positions "EMAAR.XDFM",
    # activities "EMAAR"). The exact match misses, so we used to create a second
    # Security and split the holding and its trades across two rows — permanent,
    # since Sure has no security merge. When this account already syncs a security
    # whose ticker normalizes to the same key, reuse that spelling instead.
    # No match, or more than one candidate → nil, i.e. today's behaviour.
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

    def create_security_from_row(ticker)
      Security.create!(ticker: ticker, name: ticker)
    end
end
