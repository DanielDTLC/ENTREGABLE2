-- =====================================================================
-- ENTREGABLE 2 - DATA MART OLIST (PostgreSQL)
-- 01_crear_tablas.sql : staging + dimensiones + hechos
-- Granularidad fact_ventas: UNA FILA = UN ÍTEM DE UN PEDIDO (order_id + order_item_id)
-- Granularidad fact_pagos : UNA FILA = UN PAGO (order_id + payment_sequential)
-- =====================================================================

-- Crear la base (ejecutar desde psql conectado a "postgres"):
-- (No hace falta crear la base: Docker ya crea bi_database)


DROP SCHEMA IF EXISTS stg CASCADE;
DROP SCHEMA IF EXISTS dw  CASCADE;
CREATE SCHEMA stg;   -- datos crudos (todo texto)
CREATE SCHEMA dw;    -- data mart
SET search_path TO dw, stg, public;

-- ---------------------------------------------------------------------
-- STAGING (todo TEXT: se carga tal cual el CSV, se limpia al pasar al DW)
-- ---------------------------------------------------------------------
CREATE TABLE stg.orders (
    order_id TEXT, customer_id TEXT, order_status TEXT,
    order_purchase_timestamp TEXT, order_approved_at TEXT,
    order_delivered_carrier_date TEXT, order_delivered_customer_date TEXT,
    order_estimated_delivery_date TEXT
);
CREATE TABLE stg.order_items (
    order_id TEXT, order_item_id TEXT, product_id TEXT, seller_id TEXT,
    shipping_limit_date TEXT, price TEXT, freight_value TEXT
);
CREATE TABLE stg.order_payments (
    order_id TEXT, payment_sequential TEXT, payment_type TEXT,
    payment_installments TEXT, payment_value TEXT
);
CREATE TABLE stg.order_reviews (
    review_id TEXT, order_id TEXT, review_score TEXT,
    review_comment_title TEXT, review_comment_message TEXT,
    review_creation_date TEXT, review_answer_timestamp TEXT
);
CREATE TABLE stg.customers (
    customer_id TEXT, customer_unique_id TEXT,
    customer_zip_code_prefix TEXT, customer_city TEXT, customer_state TEXT
);
CREATE TABLE stg.products (
    product_id TEXT, product_category_name TEXT,
    product_name_lenght TEXT, product_description_lenght TEXT,
    product_photos_qty TEXT, product_weight_g TEXT,
    product_length_cm TEXT, product_height_cm TEXT, product_width_cm TEXT
);
CREATE TABLE stg.sellers (
    seller_id TEXT, seller_zip_code_prefix TEXT, seller_city TEXT, seller_state TEXT
);
CREATE TABLE stg.category_translation (
    product_category_name TEXT, product_category_name_english TEXT
);

-- ---------------------------------------------------------------------
-- DIMENSIONES
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_fecha (
    sk_fecha      INT PRIMARY KEY,          -- formato YYYYMMDD
    fecha         DATE NOT NULL UNIQUE,
    dia           SMALLINT NOT NULL,
    mes           SMALLINT NOT NULL,
    nombre_mes    VARCHAR(15) NOT NULL,
    trimestre     SMALLINT NOT NULL,
    anio          SMALLINT NOT NULL,
    dia_semana    VARCHAR(12) NOT NULL,
    es_fin_semana BOOLEAN NOT NULL
);

CREATE TABLE dw.dim_cliente (
    sk_cliente         SERIAL PRIMARY KEY,
    customer_id        VARCHAR(40) NOT NULL UNIQUE,  -- cambia en cada pedido
    customer_unique_id VARCHAR(40) NOT NULL,         -- persona real (para recompra)
    ciudad             VARCHAR(100),
    estado             CHAR(2),
    cp_prefijo         VARCHAR(5)
);

CREATE TABLE dw.dim_producto (
    sk_producto   SERIAL PRIMARY KEY,
    product_id    VARCHAR(40) NOT NULL UNIQUE,
    categoria_pt  VARCHAR(100) NOT NULL,
    categoria_en  VARCHAR(100) NOT NULL,
    peso_g        NUMERIC(10,2)
);

CREATE TABLE dw.dim_vendedor (
    sk_vendedor SERIAL PRIMARY KEY,
    seller_id   VARCHAR(40) NOT NULL UNIQUE,
    ciudad      VARCHAR(100),
    estado      CHAR(2),
    cp_prefijo  VARCHAR(5)
);

CREATE TABLE dw.dim_estado_pedido (
    sk_estado_pedido SERIAL PRIMARY KEY,
    order_status     VARCHAR(20) NOT NULL UNIQUE,
    descripcion      VARCHAR(100)
);

CREATE TABLE dw.dim_pago (
    sk_pago   SERIAL PRIMARY KEY,
    tipo_pago VARCHAR(20) NOT NULL UNIQUE
);

-- ---------------------------------------------------------------------
-- TABLAS DE HECHOS
-- ---------------------------------------------------------------------
CREATE TABLE dw.fact_ventas (
    sk_venta             BIGSERIAL PRIMARY KEY,
    order_id             VARCHAR(40) NOT NULL,       -- clave degenerada
    order_item_id        SMALLINT    NOT NULL,       -- clave degenerada
    sk_fecha_compra      INT NOT NULL REFERENCES dw.dim_fecha(sk_fecha),
    sk_fecha_aprobacion  INT REFERENCES dw.dim_fecha(sk_fecha),
    sk_fecha_despacho    INT REFERENCES dw.dim_fecha(sk_fecha),
    sk_fecha_entrega     INT REFERENCES dw.dim_fecha(sk_fecha),
    sk_fecha_estimada    INT REFERENCES dw.dim_fecha(sk_fecha),
    sk_cliente           INT NOT NULL REFERENCES dw.dim_cliente(sk_cliente),
    sk_producto          INT NOT NULL REFERENCES dw.dim_producto(sk_producto),
    sk_vendedor          INT NOT NULL REFERENCES dw.dim_vendedor(sk_vendedor),
    sk_estado_pedido     INT NOT NULL REFERENCES dw.dim_estado_pedido(sk_estado_pedido),
    -- medidas
    price                NUMERIC(10,2) NOT NULL,
    freight_value        NUMERIC(10,2) NOT NULL,
    dias_entrega         NUMERIC(6,2),               -- entrega - compra
    dias_retraso         NUMERIC(6,2),               -- entrega - estimada (>0 = tarde)
    flag_entrega_tardia  SMALLINT,                   -- 1 tarde, 0 a tiempo, NULL no aplica
    flag_inconsistente   SMALLINT NOT NULL DEFAULT 0,-- 1 = error de registro de fechas
    review_score         SMALLINT,                   -- por PEDIDO (se repite en cada ítem)
    CONSTRAINT uq_fact_ventas UNIQUE (order_id, order_item_id),
    CONSTRAINT ck_review CHECK (review_score IS NULL OR review_score BETWEEN 1 AND 5)
);

CREATE TABLE dw.fact_pagos (
    sk_pago_fact       BIGSERIAL PRIMARY KEY,
    order_id           VARCHAR(40) NOT NULL,
    payment_sequential SMALLINT NOT NULL,
    sk_fecha_compra    INT NOT NULL REFERENCES dw.dim_fecha(sk_fecha),
    sk_cliente         INT NOT NULL REFERENCES dw.dim_cliente(sk_cliente),
    sk_pago            INT NOT NULL REFERENCES dw.dim_pago(sk_pago),
    cuotas             SMALLINT,
    valor_pago         NUMERIC(10,2) NOT NULL,
    CONSTRAINT uq_fact_pagos UNIQUE (order_id, payment_sequential)
);

-- Índices sobre claves foráneas (mejoran joins del dashboard)
CREATE INDEX ix_fv_fecha    ON dw.fact_ventas(sk_fecha_compra);
CREATE INDEX ix_fv_cliente  ON dw.fact_ventas(sk_cliente);
CREATE INDEX ix_fv_producto ON dw.fact_ventas(sk_producto);
CREATE INDEX ix_fv_vendedor ON dw.fact_ventas(sk_vendedor);
CREATE INDEX ix_fv_estado   ON dw.fact_ventas(sk_estado_pedido);
CREATE INDEX ix_fp_pago     ON dw.fact_pagos(sk_pago);
