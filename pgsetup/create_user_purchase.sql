CREATE SCHEMA retail;
CREATE TABLE retail.user_purchase (
    invoice_number VARCHAR(10),
    stock_code VARCHAR(20),
    detail VARCHAR(1000),
    quantity INT,
    invoice_date TIMESTAMP,
    unit_price NUMERIC(8,3),
    customer_id INT,
    country VARCHAR(20)
);
COPY retail.user_purchase(
    invoice_number,
    stock_code,
    detail,
    quantity,
    invoice_date,
    unit_price,
    customer_id,
    country
)
FROM '/input_data/OnlineRetail.csv' DELIMITER ',' CSV HEADER;