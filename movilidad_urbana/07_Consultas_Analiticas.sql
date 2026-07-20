-- SCRIPT 07: Consultas analíticas

USE movilidad_urbana;

-- Horas de mayor afluencia con ranking
SELECT
  hora,
  total_viajes,
  @rank := @rank + 1 AS ranking_hora
FROM (
  SELECT HOUR(fecha_hora_inicio) AS hora, COUNT(*) AS total_viajes
  FROM Viajes
  WHERE estado = 'completado'
  GROUP BY hora
  ORDER BY total_viajes DESC
) sub
CROSS JOIN (SELECT @rank := 0) init;

-- Conductores con caída intermensual > 5%
SELECT
  vm1.id_conductor,
  CONCAT(c.nombre, ' ', c.apellido) AS nombre_conductor,
  vm1.mes,
  vm1.viajes,
  vm2.viajes AS viajes_mes_anterior,
  ROUND((vm1.viajes - vm2.viajes) / vm2.viajes * 100, 2) AS cambio_porcentual
FROM (
  SELECT
    ve.id_conductor,
    DATE_FORMAT(v.fecha_hora_inicio, '%Y-%m') AS mes,
    COUNT(*) AS viajes
  FROM Viajes v
  JOIN Vehiculos ve ON v.id_vehiculo = ve.id_vehiculo
  WHERE v.estado = 'completado'
  GROUP BY ve.id_conductor, mes
) vm1
LEFT JOIN (
  SELECT
    ve.id_conductor,
    DATE_FORMAT(v.fecha_hora_inicio, '%Y-%m') AS mes,
    COUNT(*) AS viajes
  FROM Viajes v
  JOIN Vehiculos ve ON v.id_vehiculo = ve.id_vehiculo
  WHERE v.estado = 'completado'
  GROUP BY ve.id_conductor, mes
) vm2
  ON vm1.id_conductor = vm2.id_conductor
  AND vm2.mes = DATE_FORMAT(DATE_SUB(CONCAT(vm1.mes, '-01'), INTERVAL 1 MONTH), '%Y-%m')
JOIN Conductores c ON vm1.id_conductor = c.id_conductor
WHERE vm2.viajes IS NOT NULL
  AND (vm1.viajes - vm2.viajes) / vm2.viajes < -0.05
ORDER BY cambio_porcentual ASC;

-- Segmentación de clientes de alto valor (cuartil superior)
SELECT
  numerado.id_cliente,
  CONCAT(cl.nombre, ' ', cl.apellido) AS nombre_cliente,
  numerado.total_gastado,
  numerado.row_num,
  numerado.total_clientes,
  CASE WHEN numerado.row_num <= numerado.total_clientes * 0.25
       THEN 'Cuartil 1 (alto)' ELSE 'Otro' END AS segmento
FROM (
  SELECT
    id_cliente,
    total_gastado,
    @rownum := @rownum + 1 AS row_num,
    (SELECT COUNT(DISTINCT id_cliente) FROM Viajes WHERE estado = 'completado') AS total_clientes
  FROM (
    SELECT id_cliente, SUM(tarifa_final) AS total_gastado
    FROM Viajes
    WHERE estado = 'completado'
    GROUP BY id_cliente
    ORDER BY total_gastado DESC
  ) gasto,
  (SELECT @rownum := 0) r
) numerado
JOIN Clientes cl ON numerado.id_cliente = cl.id_cliente   
WHERE numerado.row_num <= numerado.total_clientes * 0.25
ORDER BY numerado.total_gastado DESC;

-- Detección de viajes con velocidad atípica (> media + 2σ)
SELECT v.*, ROUND(v.velocidad_kmh, 1) AS velocidad_kmh_redondeada
FROM (
  SELECT
    id_viaje,
    distancia_km,
    TIMESTAMPDIFF(MINUTE, fecha_hora_inicio, fecha_hora_fin) AS duracion_min,
    distancia_km / (TIMESTAMPDIFF(MINUTE, fecha_hora_inicio, fecha_hora_fin)/60) AS velocidad_kmh
  FROM Viajes
  WHERE estado = 'completado'
    AND fecha_hora_fin IS NOT NULL
    AND TIMESTAMPDIFF(MINUTE, fecha_hora_inicio, fecha_hora_fin) > 0
) v
CROSS JOIN (
  SELECT
    AVG(velocidad) AS media,
    STDDEV(velocidad) AS desvest
  FROM (
    SELECT distancia_km / (TIMESTAMPDIFF(MINUTE, fecha_hora_inicio, fecha_hora_fin)/60) AS velocidad
    FROM Viajes
    WHERE estado = 'completado'
      AND fecha_hora_fin IS NOT NULL
      AND TIMESTAMPDIFF(MINUTE, fecha_hora_inicio, fecha_hora_fin) > 0
  ) vel_sub
) stats
WHERE v.velocidad_kmh > stats.media + 2 * stats.desvest;

-- Dataset para predicción de demanda horaria (features)
SELECT
  dh.fecha,
  dh.hora,
  dh.dia_semana,
  dh.num_viajes,
  dh.tarifa_promedio,
  dh.conductores_unicos,
  COALESCE(
    (SELECT num_viajes
     FROM (
       SELECT DATE(fecha_hora_inicio) AS f, HOUR(fecha_hora_inicio) AS h, COUNT(*) AS num_viajes
       FROM Viajes
       WHERE estado = 'completado'
       GROUP BY f, h
     ) t
     WHERE (t.f = dh.fecha AND t.h = dh.hora - 1)
        OR (t.f = DATE_SUB(dh.fecha, INTERVAL 1 DAY) AND dh.hora = 0 AND t.h = 23)
     LIMIT 1),
  0) AS viajes_hora_anterior
FROM (
  SELECT
    DATE(v.fecha_hora_inicio) AS fecha,
    HOUR(v.fecha_hora_inicio) AS hora,
    DAYOFWEEK(v.fecha_hora_inicio) AS dia_semana,
    COUNT(*) AS num_viajes,
    AVG(v.tarifa_final) AS tarifa_promedio,
    COUNT(DISTINCT ve.id_conductor) AS conductores_unicos
  FROM Viajes v
  JOIN Vehiculos ve ON v.id_vehiculo = ve.id_vehiculo
  WHERE v.estado = 'completado'
  GROUP BY fecha, hora, dia_semana
) dh
ORDER BY dh.fecha, dh.hora;
