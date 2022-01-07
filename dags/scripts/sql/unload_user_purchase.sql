COPY (
    SELECT  invoice_number,
            stock_code,
            detail,
            quantity,
            invoice_date,
            unit_price,
            customer_id,
            country
    FROM retail.user_purchase -- we should have a date filter here to pull only required data
) TO '{{ params.user_purchase }}' WITH (FORMAT CSV, HEADER);