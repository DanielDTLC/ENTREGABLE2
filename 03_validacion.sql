-- =====================================================================
-- 03_validacion.sql : evidencia de carga e integridad
-- (toma captura de cada resultado para el entregable)
-- =====================================================================
SET search_path TO dw, stg, public;

-- 1) CANTIDAD DE REGISTROS CARGADOS (comparar con lo esperado)
SELECT 'dim_fecha' AS tabla, COUNT(*) AS filas, NULL::bigint AS esperado FROM dim_fecha
UNION ALL SELECT 'dim_cliente',       COUNT(*), 99441  FROM dim_cliente
UNION ALL SELECT 'dim_producto',      COUNT(*), 32951  FROM dim_producto
UNION ALL SELECT 'dim_vendedor',      COUNT(*), 3095   FROM dim_vendedor
UNION ALL SELECT 'dim_estado_pedido', COUNT(*), 8      FROM dim_estado_pedido
UNION ALL SELECT 'dim_pago',          COUNT(*), 5      FROM dim_pago
UNION ALL SELECT 'fact_ventas',       COUNT(*), 112650 FROM fact_ventas
UNION ALL SELECT 'fact_pagos',        COUNT(*), 103877 FROM fact_pagos;  -- 103.886 - 9 pagos en 0

-- Staging vs DW (no se debe perder ningún ítem)
SELECT (SELECT COUNT(*) FROM stg.order_items) AS items_staging,
       (SELECT COUNT(*) FROM fact_ventas)     AS items_fact;

-- 2) INTEGRIDAD DE RELACIONES (todas deben dar 0)
SELECT 'ventas sin cliente'  AS chequeo, COUNT(*) FROM fact_ventas f LEFT JOIN dim_cliente  d ON d.sk_cliente=f.sk_cliente   WHERE d.sk_cliente IS NULL
UNION ALL SELECT 'ventas sin producto', COUNT(*) FROM fact_ventas f LEFT JOIN dim_producto d ON d.sk_producto=f.sk_producto WHERE d.sk_producto IS NULL
UNION ALL SELECT 'ventas sin vendedor', COUNT(*) FROM fact_ventas f LEFT JOIN dim_vendedor d ON d.sk_vendedor=f.sk_vendedor WHERE d.sk_vendedor IS NULL
UNION ALL SELECT 'ventas sin fecha compra', COUNT(*) FROM fact_ventas f LEFT JOIN dim_fecha d ON d.sk_fecha=f.sk_fecha_compra WHERE d.sk_fecha IS NULL
UNION ALL SELECT 'pagos sin tipo de pago', COUNT(*) FROM fact_pagos f LEFT JOIN dim_pago d ON d.sk_pago=f.sk_pago WHERE d.sk_pago IS NULL
UNION ALL SELECT 'duplicados fact_ventas', COUNT(*) FROM (SELECT order_id, order_item_id FROM fact_ventas GROUP BY 1,2 HAVING COUNT(*)>1) x;

-- 3) VALORES NULOS RELEVANTES
SELECT COUNT(*)                                          AS total_items,
       COUNT(*) FILTER (WHERE sk_fecha_aprobacion IS NULL) AS sin_aprobacion,
       COUNT(*) FILTER (WHERE sk_fecha_despacho   IS NULL) AS sin_despacho,
       COUNT(*) FILTER (WHERE sk_fecha_entrega    IS NULL) AS sin_entrega,
       COUNT(*) FILTER (WHERE review_score        IS NULL) AS sin_resena,
       COUNT(*) FILTER (WHERE flag_inconsistente = 1)      AS inconsistentes
FROM fact_ventas;

SELECT COUNT(*) FILTER (WHERE categoria_en = 'unknown') AS productos_sin_categoria,
       COUNT(*) FILTER (WHERE peso_g IS NULL)           AS productos_sin_peso
FROM dim_producto;

-- 4) TOTALES / MEDIDAS PRINCIPALES
SELECT SUM(price)                     AS ingreso_items,      -- aprox. 13,59 M
       SUM(freight_value)             AS flete_total,        -- aprox. 2,25 M
       COUNT(DISTINCT order_id)       AS pedidos_con_items,
       ROUND(AVG(dias_entrega) FILTER (WHERE flag_inconsistente=0),2) AS dias_entrega_prom,
       ROUND(100.0*SUM(flag_entrega_tardia) FILTER (WHERE order_item_id=1 AND flag_inconsistente=0)
             / NULLIF(COUNT(flag_entrega_tardia) FILTER (WHERE order_item_id=1 AND flag_inconsistente=0),0),2) AS pct_tardias
FROM fact_ventas;

SELECT ROUND(AVG(review_score) FILTER (WHERE order_item_id=1),2) AS calificacion_prom_por_pedido
FROM fact_ventas;

SELECT (SELECT SUM(price) FROM fact_ventas)::numeric(14,2)           AS ventas_dw,
       (SELECT SUM(price::numeric) FROM stg.order_items)::numeric(14,2) AS ventas_staging; -- deben coincidir
