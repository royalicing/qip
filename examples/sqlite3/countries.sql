CREATE TABLE
    countries (
        iso_3166_code TEXT PRIMARY KEY CHECK (length (iso_3166_code) = 2),
        name_en TEXT NOT NULL,
        currency TEXT NOT NULL
    );

-- 14 countries
INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('AU', 'Australia', 'AUD');

INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('ID', 'Indonesia', 'IDR');

INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('MN', 'Mongolia', 'MNT');

INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('SD', 'Sudan', 'SDG');

INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('PL', 'Poland', 'PLN');

INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('MW', 'Malawi', 'MWK');

INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('US', 'United States', 'USD');

INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('JP', 'Japan', 'JPY');

INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('DE', 'Germany', 'EUR');

INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('IN', 'India', 'INR');

INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('BR', 'Brazil', 'BRL');

INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('ZA', 'South Africa', 'ZAR');

INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('CA', 'Canada', 'CAD');

INSERT INTO
    countries (iso_3166_code, name_en, currency)
VALUES
    ('CN', 'China', 'CNY');

-- Calling codes (E.164 country codes; some countries share/overlap like NANP)
CREATE TABLE
    country_calling_codes (
        country_code TEXT NOT NULL REFERENCES countries (iso_3166_code) ON DELETE CASCADE,
        calling_code TEXT NOT NULL,
        PRIMARY KEY (country_code, calling_code),
        CHECK (
            calling_code GLOB '[0-9]*'
            AND length (calling_code) BETWEEN 1 AND 3
        )
    );

CREATE INDEX country_calling_codes_code_idx ON country_calling_codes (calling_code);

INSERT INTO
    country_calling_codes (country_code, calling_code)
VALUES
    ('AU', '61'),
    ('ID', '62'),
    ('MN', '976'),
    ('SD', '249'),
    ('PL', '48'),
    ('MW', '265'),
    ('US', '1'),
    ('JP', '81'),
    ('DE', '49'),
    ('IN', '91'),
    ('BR', '55'),
    ('ZA', '27'),
    ('CA', '1'),
    ('CN', '86');

-- Time zones (IANA tz database IDs)
CREATE TABLE
    time_zones (tzid TEXT PRIMARY KEY);

CREATE TABLE
    country_time_zones (
        country_code TEXT NOT NULL REFERENCES countries (iso_3166_code) ON DELETE CASCADE,
        tzid TEXT NOT NULL REFERENCES time_zones (tzid),
        PRIMARY KEY (country_code, tzid)
    );

CREATE INDEX country_time_zones_country_idx ON country_time_zones (country_code);

CREATE INDEX country_time_zones_tzid_idx ON country_time_zones (tzid);

-- Sample (representative) time zones for each country
INSERT INTO
    time_zones (tzid)
VALUES
    ('Australia/Perth'),
    ('Australia/Adelaide'),
    ('Australia/Darwin'),
    ('Australia/Brisbane'),
    ('Australia/Sydney'),
    ('Australia/Hobart'),
    ('Australia/Lord_Howe'),
    ('Australia/Eucla'),
    ('Asia/Jakarta'),
    ('Asia/Makassar'),
    ('Asia/Jayapura'),
    ('Asia/Ulaanbaatar'),
    ('Asia/Hovd'),
    ('Asia/Choibalsan'),
    ('Africa/Khartoum'),
    ('Europe/Warsaw'),
    ('Africa/Blantyre'),
    ('America/New_York'),
    ('America/Chicago'),
    ('America/Denver'),
    ('America/Los_Angeles'),
    ('America/Anchorage'),
    ('Pacific/Honolulu'),
    ('Asia/Tokyo'),
    ('Europe/Berlin'),
    ('Asia/Kolkata'),
    ('America/Sao_Paulo'),
    ('America/Manaus'),
    ('America/Recife'),
    ('America/Rio_Branco'),
    ('America/Noronha'),
    ('Africa/Johannesburg'),
    ('America/Toronto'),
    ('America/Winnipeg'),
    ('America/Edmonton'),
    ('America/Vancouver'),
    ('America/Halifax'),
    ('America/St_Johns'),
    ('Asia/Shanghai'),
    ('Asia/Urumqi');

INSERT INTO
    country_time_zones (country_code, tzid)
VALUES
    ('AU', 'Australia/Perth'),
    ('AU', 'Australia/Adelaide'),
    ('AU', 'Australia/Darwin'),
    ('AU', 'Australia/Brisbane'),
    ('AU', 'Australia/Sydney'),
    ('AU', 'Australia/Hobart'),
    ('AU', 'Australia/Lord_Howe'),
    ('AU', 'Australia/Eucla'),
    ('ID', 'Asia/Jakarta'),
    ('ID', 'Asia/Makassar'),
    ('ID', 'Asia/Jayapura'),
    ('MN', 'Asia/Ulaanbaatar'),
    ('MN', 'Asia/Hovd'),
    ('MN', 'Asia/Choibalsan'),
    ('SD', 'Africa/Khartoum'),
    ('PL', 'Europe/Warsaw'),
    ('MW', 'Africa/Blantyre'),
    ('US', 'America/New_York'),
    ('US', 'America/Chicago'),
    ('US', 'America/Denver'),
    ('US', 'America/Los_Angeles'),
    ('US', 'America/Anchorage'),
    ('US', 'Pacific/Honolulu'),
    ('JP', 'Asia/Tokyo'),
    ('DE', 'Europe/Berlin'),
    ('IN', 'Asia/Kolkata'),
    ('BR', 'America/Sao_Paulo'),
    ('BR', 'America/Manaus'),
    ('BR', 'America/Recife'),
    ('BR', 'America/Rio_Branco'),
    ('BR', 'America/Noronha'),
    ('ZA', 'Africa/Johannesburg'),
    ('CA', 'America/Toronto'),
    ('CA', 'America/Winnipeg'),
    ('CA', 'America/Edmonton'),
    ('CA', 'America/Vancouver'),
    ('CA', 'America/Halifax'),
    ('CA', 'America/St_Johns'),
    ('CN', 'Asia/Shanghai'),
    ('CN', 'Asia/Urumqi');