-- =====================================================================
-- 02_carga_datos.sql : carga a staging + limpieza + carga al data mart
-- Ejecutar con psql dentro del contenedor (ver README). CSV en /work/olist/
-- =====================================================================
SET search_path TO dw, stg, public;

-- ---------------------------------------------------------------------
-- 1) CARGA CRUDA A STAGING
-- ---------------------------------------------------------------------
TRUNCATE stg.orders, stg.order_items, stg.order_payments, stg.order_reviews,
         stg.customers, stg.products, stg.sellers, stg.category_translation;

\copy stg.orders               FROM '/work/olist/olist_orders_dataset.csv'               CSV HEADER ENCODING 'UTF8'
\copy stg.order_items          FROM '/work/olist/olist_order_items_dataset.csv'          CSV HEADER ENCODING 'UTF8'
\copy stg.order_payments       FROM '/work/olist/olist_order_payments_dataset.csv'       CSV HEADER ENCODING 'UTF8'
\copy stg.order_reviews        FROM '/work/olist/olist_order_reviews_dataset.csv'        CSV HEADER ENCODING 'UTF8'
\copy stg.customers            FROM '/work/olist/olist_customers_dataset.csv'            CSV HEADER ENCODING 'UTF8'
\copy stg.products             FROM '/work/olist/olist_products_dataset.csv'             CSV HEADER ENCODING 'UTF8'
\copy stg.sellers              FROM '/work/olist/olist_sellers_dataset.csv'              CSV HEADER ENCODING 'UTF8'
\copy stg.category_translation FROM '/work/olist/product_category_name_translation.csv'  CSV HEADER ENCODING 'UTF8'

-- ---------------------------------------------------------------------
-- 2) DIMENSIONES
-- ---------------------------------------------------------------------

-- dim_fecha: generada (cubre 2016-2018 completo)
INSERT INTO dw.dim_fecha
SELECT to_char(d,'YYYYMMDD')::int,
       d::date,
       EXTRACT(DAY FROM d)::smallint,
       EXTRACT(MONTH FROM d)::smallint,
       (ARRAY['Enero','Febrero','Marzo','Abril','Mayo','Junio','Julio','Agosto',
              'Septiembre','Octubre','Noviembre','Diciembre'])[EXTRACT(MONTH FROM d)::int],
       EXTRACT(QUARTER FROM d)::smallint,
       EXTRACT(YEAR FROM d)::smallint,
       (ARRAY['Lunes','Martes','Miércoles','Jueves','Viernes','Sábado','Domingo'])[EXTRACT(ISODOW FROM d)::int],
       EXTRACT(ISODOW FROM d) IN (6,7)
FROM generate_series('2016-01-01'::date, '2018-12-31'::date, interval '1 day') AS d;

-- dim_cliente (grano customer_id; customer_unique_id identifica a la persona)
INSERT INTO dw.dim_cliente (customer_id, customer_unique_id, ciudad, estado, cp_prefijo)
SELECT DISTINCT customer_id, customer_unique_id,
       INITCAP(TRIM(customer_city)), UPPER(TRIM(customer_state)),
       LPAD(customer_zip_code_prefix, 5, '0')
FROM stg.customers;

-- dim_producto: categoría nula -> 'desconocida'; traducciones faltantes manuales
INSERT INTO dw.dim_producto (product_id, categoria_pt, categoria_en, peso_g)
SELECT p.product_id,
       COALESCE(NULLIF(TRIM(p.product_category_name),''), 'desconocida'),
       CASE
         WHEN NULLIF(TRIM(p.product_category_name),'') IS NULL THEN 'unknown'
         WHEN p.product_category_name = 'pc_gamer' THEN 'pc_gamer'
         WHEN p.product_category_name = 'portateis_cozinha_e_preparadores_de_alimentos'
              THEN 'portable_kitchen_food_preparers'
         ELSE COALESCE(t.product_category_name_english, p.product_category_name)
       END,
       NULLIF(p.product_weight_g,'')::numeric
FROM stg.products p
LEFT JOIN stg.category_translation t USING (product_category_name);

-- dim_vendedor
INSERT INTO dw.dim_vendedor (seller_id, ciudad, estado, cp_prefijo)
SELECT DISTINCT seller_id, INITCAP(TRIM(seller_city)), UPPER(TRIM(seller_state)),
       LPAD(seller_zip_code_prefix, 5, '0')
FROM stg.sellers;

-- dim_estado_pedido
INSERT INTO dw.dim_estado_pedido (order_status, descripcion) VALUES
 ('created','Creado'),('approved','Aprobado'),('invoiced','Facturado'),
 ('processing','En procesamiento'),('shipped','Enviado'),('delivered','Entregado'),
 ('unavailable','No disponible'),('canceled','Cancelado');

-- dim_pago ('not_defined' se agrupa como 'no_definido')
INSERT INTO dw.dim_pago (tipo_pago)
SELECT DISTINCT CASE WHEN payment_type='not_defined' THEN 'no_definido' ELSE payment_type END
FROM stg.order_payments;

-- ---------------------------------------------------------------------
-- 3) FACT_VENTAS (grano: un ítem de pedido)
-- ---------------------------------------------------------------------
-- Reseña: se conserva la MÁS RECIENTE por pedido (hay pedidos con varias)
WITH resena AS (
    SELECT DISTINCT ON (order_id) order_id, review_score::smallint AS review_score
    FROM stg.order_reviews
    ORDER BY order_id, review_answer_timestamp DESC NULLS LAST
),
base AS (
    SELECT i.order_id, i.order_item_id::smallint AS order_item_id,
           i.product_id, i.seller_id, o.customer_id, o.order_status,
           i.price::numeric AS price, i.freight_value::numeric AS freight_value,
           o.order_purchase_timestamp::timestamp        AS f_compra,
           o.order_approved_at::timestamp               AS f_aprob,
           o.order_delivered_carrier_date::timestamp    AS f_desp,
           o.order_delivered_customer_date::timestamp   AS f_entrega,
           o.order_estimated_delivery_date::timestamp   AS f_estim
    FROM stg.order_items i
    JOIN stg.orders o USING (order_id)
)
INSERT INTO dw.fact_ventas
    (order_id, order_item_id, sk_fecha_compra, sk_fecha_aprobacion, sk_fecha_despacho,
     sk_fecha_entrega, sk_fecha_estimada, sk_cliente, sk_producto, sk_vendedor,
     sk_estado_pedido, price, freight_value, dias_entrega, dias_retraso,
     flag_entrega_tardia, flag_inconsistente, review_score)
SELECT b.order_id, b.order_item_id,
       to_char(b.f_compra,'YYYYMMDD')::int,
       to_char(b.f_aprob ,'YYYYMMDD')::int,
       to_char(b.f_desp  ,'YYYYMMDD')::int,
       to_char(b.f_entrega,'YYYYMMDD')::int,
       to_char(b.f_estim ,'YYYYMMDD')::int,
       c.sk_cliente, p.sk_producto, v.sk_vendedor, e.sk_estado_pedido,
       b.price, b.freight_value,
       ROUND((EXTRACT(EPOCH FROM (b.f_entrega - b.f_compra))/86400)::numeric, 2),
       ROUND((EXTRACT(EPOCH FROM (b.f_entrega - b.f_estim ))/86400)::numeric, 2),
       CASE WHEN b.f_entrega IS NULL THEN NULL
            WHEN b.f_entrega > b.f_estim THEN 1 ELSE 0 END,
       -- inconsistente: 'delivered' sin fecha de entrega, o entrega antes del despacho
       CASE WHEN (b.order_status='delivered' AND b.f_entrega IS NULL)
              OR (b.f_entrega IS NOT NULL AND b.f_desp IS NOT NULL AND b.f_entrega < b.f_desp)
            THEN 1 ELSE 0 END,
       r.review_score
FROM base b
JOIN dw.dim_cliente       c ON c.customer_id = b.customer_id
JOIN dw.dim_producto      p ON p.product_id  = b.product_id
JOIN dw.dim_vendedor      v ON v.seller_id   = b.seller_id
JOIN dw.dim_estado_pedido e ON e.order_status = b.order_status
LEFT JOIN resena r ON r.order_id = b.order_id;

-- ---------------------------------------------------------------------
-- 4) FACT_PAGOS (grano: un pago de un pedido). Se excluyen pagos con valor 0
-- ---------------------------------------------------------------------
INSERT INTO dw.fact_pagos
    (order_id, payment_sequential, sk_fecha_compra, sk_cliente, sk_pago, cuotas, valor_pago)
SELECT pg.order_id, pg.payment_sequential::smallint,
       to_char(o.order_purchase_timestamp::timestamp,'YYYYMMDD')::int,
       c.sk_cliente, dp.sk_pago,
       NULLIF(pg.payment_installments::int, 0),
       pg.payment_value::numeric
FROM stg.order_payments pg
JOIN stg.orders o USING (order_id)
JOIN dw.dim_cliente c ON c.customer_id = o.customer_id
JOIN dw.dim_pago   dp ON dp.tipo_pago =
        CASE WHEN pg.payment_type='not_defined' THEN 'no_definido' ELSE pg.payment_type END
WHERE pg.payment_value::numeric > 0;

ANALYZE;
