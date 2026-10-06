# Proyecto Olist - Entregable 2
1. Copia los 8 CSV en la carpeta `olist/`.
2. En esta carpeta: `docker compose up -d`
3. Ejecuta, en orden:
   docker exec -i bi-postgres psql -U bi_user -d bi_database -f /work/01_crear_tablas.sql
   docker exec -i bi-postgres psql -U bi_user -d bi_database -f /work/02_carga_datos.sql
   docker exec -i bi-postgres psql -U bi_user -d bi_database -f /work/03_validacion.sql
   docker exec -i bi-postgres psql -U bi_user -d bi_database -f /work/04_vistas_funciones.sql
Conexion (DataGrip/VS Code): localhost:5432, db bi_database, user bi_user, pass bi_password
Apagar: docker compose down
