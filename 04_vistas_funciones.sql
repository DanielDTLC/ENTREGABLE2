-- =====================================================================
-- 04_vistas_funciones.sql : capa de consumo del dashboard
-- Regla: review_score y conteo de pedidos se toman con order_item_id = 1
-- (una fila por pedido) para no ponderar por ítem.
-- =====================================================================
SET search_path TO dw, public;

-- ---------------------------------------------------------------------
-- FUNCIONES (KPI con filtros opcionales: NULL = sin filtro)
-- ---------------------------------------------------------------------

-- KPI 1: Ingresos por ventas (GMV), excluye pedidos cancelados
CREATE OR REPLACE FUNCTION fn_total_ventas(p_anio INT DEFAULT NULL, p_categoria TEXT DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(f.price), 0)
    FROM fact_ventas f
    JOIN dim_fecha d         ON d.sk_fecha = f.sk_fecha_compra
    JOIN dim_producto p      ON p.sk_producto = f.sk_producto
    JOIN dim_estado_pedido e ON e.sk_estado_pedido = f.sk_estado_pedido
    WHERE e.order_status <> 'canceled'
      AND (p_anio IS NULL OR d.anio = p_anio)
      AND (p_categoria IS NULL OR p.categoria_en = p_categoria);
$$;

-- KPI 2: Ticket promedio por pedido (precio + flete)
CREATE OR REPLACE FUNCTION fn_ticket_promedio(p_anio INT DEFAULT NULL, p_categoria TEXT DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT ROUND(SUM(f.price + f.freight_value) / NULLIF(COUNT(DISTINCT f.order_id),0), 2)
    FROM fact_ventas f
    JOIN dim_fecha d         ON d.sk_fecha = f.sk_fecha_compra
    JOIN dim_producto p      ON p.sk_producto = f.sk_producto
    JOIN dim_estado_pedido e ON e.sk_estado_pedido = f.sk_estado_pedido
    WHERE e.order_status <> 'canceled'
      AND (p_anio IS NULL OR d.anio = p_anio)
      AND (p_categoria IS NULL OR p.categoria_en = p_categoria);
$$;

-- KPI 3: % de entregas tardías (sobre pedidos entregados y consistentes)
CREATE OR REPLACE FUNCTION fn_pct_entregas_tardias(p_anio INT DEFAULT NULL, p_estado CHAR(2) DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT ROUND(100.0 * SUM(f.flag_entrega_tardia) / NULLIF(COUNT(f.flag_entrega_tardia),0), 2)
    FROM fact_ventas f
    JOIN dim_fecha d    ON d.sk_fecha = f.sk_fecha_compra
    JOIN dim_cliente c  ON c.sk_cliente = f.sk_cliente
    WHERE f.order_item_id = 1
      AND f.flag_inconsistente = 0
      AND (p_anio IS NULL OR d.anio = p_anio)
      AND (p_estado IS NULL OR c.estado = p_estado);
$$;

-- KPI 4: Calificación promedio (una nota por pedido)
CREATE OR REPLACE FUNCTION fn_calificacion_promedio(p_anio INT DEFAULT NULL, p_estado CHAR(2) DEFAULT NULL)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT ROUND(AVG(f.review_score), 2)
    FROM fact_ventas f
    JOIN dim_fecha d   ON d.sk_fecha = f.sk_fecha_compra
    JOIN dim_cliente c ON c.sk_cliente = f.sk_cliente
    WHERE f.order_item_id = 1
      AND (p_anio IS NULL OR d.anio = p_anio)
      AND (p_estado IS NULL OR c.estado = p_estado);
$$;

-- KPI 5: Tasa de recompra (clientes con 2+ pedidos / clientes totales)
CREATE OR REPLACE FUNCTION fn_tasa_recompra()
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH x AS (
        SELECT c.customer_unique_id, COUNT(DISTINCT f.order_id) AS pedidos
        FROM fact_ventas f JOIN dim_cliente c ON c.sk_cliente = f.sk_cliente
        GROUP BY 1)
    SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE pedidos >= 2) / COUNT(*), 2) FROM x;
$$;

-- ---------------------------------------------------------------------
-- VISTAS (gráficos y tabla de detalle)
-- ---------------------------------------------------------------------

-- Línea: ventas por mes
CREATE OR REPLACE VIEW vw_ventas_mensual AS
SELECT d.anio, d.mes, d.nombre_mes,
       SUM(f.price)                AS ingresos,
       SUM(f.freight_value)        AS flete,
       COUNT(DISTINCT f.order_id)  AS pedidos
FROM fact_ventas f
JOIN dim_fecha d         ON d.sk_fecha = f.sk_fecha_compra
JOIN dim_estado_pedido e ON e.sk_estado_pedido = f.sk_estado_pedido
WHERE e.order_status <> 'canceled'
GROUP BY d.anio, d.mes, d.nombre_mes;

-- Barras: ventas por categoría y año
CREATE OR REPLACE VIEW vw_ventas_categoria AS
SELECT d.anio, p.categoria_en AS categoria,
       SUM(f.price)               AS ingresos,
       COUNT(*)                   AS items,
       COUNT(DISTINCT f.order_id) AS pedidos
FROM fact_ventas f
JOIN dim_fecha d         ON d.sk_fecha = f.sk_fecha_compra
JOIN dim_producto p      ON p.sk_producto = f.sk_producto
JOIN dim_estado_pedido e ON e.sk_estado_pedido = f.sk_estado_pedido
WHERE e.order_status <> 'canceled'
GROUP BY d.anio, p.categoria_en;

-- Tabla: ranking de vendedores
CREATE OR REPLACE VIEW vw_top_vendedores AS
SELECT v.seller_id, v.ciudad, v.estado,
       SUM(f.price)               AS ingresos,
       COUNT(DISTINCT f.order_id) AS pedidos,
       ROUND(100.0*SUM(f.flag_entrega_tardia) FILTER (WHERE f.flag_inconsistente=0)
             / NULLIF(COUNT(f.flag_entrega_tardia) FILTER (WHERE f.flag_inconsistente=0),0),2) AS pct_tardias
FROM fact_ventas f
JOIN dim_vendedor v ON v.sk_vendedor = f.sk_vendedor
GROUP BY v.seller_id, v.ciudad, v.estado;

-- Barras: entregas por estado del cliente
CREATE OR REPLACE VIEW vw_entregas_por_estado AS
SELECT c.estado,
       COUNT(*) FILTER (WHERE f.flag_entrega_tardia IS NOT NULL) AS pedidos_entregados,
       ROUND(100.0*SUM(f.flag_entrega_tardia)/NULLIF(COUNT(f.flag_entrega_tardia),0),2) AS pct_tardias,
       ROUND(AVG(f.dias_entrega),1) AS dias_entrega_prom,
       ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.dias_entrega))::numeric,1) AS dias_entrega_mediana
FROM fact_ventas f
JOIN dim_cliente c ON c.sk_cliente = f.sk_cliente
WHERE f.order_item_id = 1 AND f.flag_inconsistente = 0
GROUP BY c.estado;

-- Barras: calificación según puntualidad
CREATE OR REPLACE VIEW vw_calificacion_vs_retraso AS
SELECT CASE f.flag_entrega_tardia WHEN 1 THEN 'Tardía' ELSE 'A tiempo' END AS puntualidad,
       COUNT(*)                        AS pedidos,
       ROUND(AVG(f.review_score), 2)   AS calificacion_prom
FROM fact_ventas f
WHERE f.order_item_id = 1 AND f.flag_inconsistente = 0
  AND f.flag_entrega_tardia IS NOT NULL AND f.review_score IS NOT NULL
GROUP BY f.flag_entrega_tardia;

-- Dona: medios de pago
CREATE OR REPLACE VIEW vw_pagos_resumen AS
SELECT dp.tipo_pago,
       COUNT(*)                          AS pagos,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),2) AS participacion_pct,
       ROUND(AVG(fp.cuotas),1)           AS cuotas_prom,
       ROUND(AVG(fp.valor_pago),2)       AS valor_prom,
       SUM(fp.valor_pago)                AS valor_total
FROM fact_pagos fp
JOIN dim_pago dp ON dp.sk_pago = fp.sk_pago
GROUP BY dp.tipo_pago;

-- Recompra por estado
CREATE OR REPLACE VIEW vw_recompra_estado AS
WITH x AS (
    SELECT c.estado, c.customer_unique_id, COUNT(DISTINCT f.order_id) AS pedidos
    FROM fact_ventas f JOIN dim_cliente c ON c.sk_cliente = f.sk_cliente
    GROUP BY c.estado, c.customer_unique_id)
SELECT estado, COUNT(*) AS clientes,
       COUNT(*) FILTER (WHERE pedidos >= 2) AS recurrentes,
       ROUND(100.0*COUNT(*) FILTER (WHERE pedidos >= 2)/COUNT(*),2) AS tasa_recompra
FROM x GROUP BY estado;

-- Tabla de detalle: un renglón por pedido (filtrable)
CREATE OR REPLACE VIEW vw_detalle_pedidos AS
SELECT f.order_id,
       dc.fecha                         AS fecha_compra,
       e.order_status                   AS estado_pedido,
       c.estado                         AS estado_cliente,
       SUM(f.price)                     AS ingresos,
       SUM(f.freight_value)             AS flete,
       MAX(f.dias_entrega)              AS dias_entrega,
       MAX(f.flag_entrega_tardia)       AS entrega_tardia,
       MAX(f.review_score)              AS calificacion
FROM fact_ventas f
JOIN dim_fecha dc        ON dc.sk_fecha = f.sk_fecha_compra
JOIN dim_cliente c       ON c.sk_cliente = f.sk_cliente
JOIN dim_estado_pedido e ON e.sk_estado_pedido = f.sk_estado_pedido
GROUP BY f.order_id, dc.fecha, e.order_status, c.estado;

-- ---------------------------------------------------------------------
-- PRUEBAS RÁPIDAS
-- ---------------------------------------------------------------------
-- SELECT fn_total_ventas();            SELECT fn_total_ventas(2018, 'health_beauty');
-- SELECT fn_ticket_promedio(2017);     SELECT fn_pct_entregas_tardias(NULL, 'SP');
-- SELECT fn_calificacion_promedio();   SELECT fn_tasa_recompra();
-- SELECT * FROM vw_calificacion_vs_retraso;
