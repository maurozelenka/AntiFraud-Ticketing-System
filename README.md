# Sistema de Venta de Entradas Antifraude (Blockchain)

Este proyecto implementa un sistema de venta y reventa de entradas en la blockchain de Ethereum para evitar la especulación y las estafas.

## ¿Qué problema soluciona?

En la reventa tradicional de entradas existen dos problemas habituales:
1. **Precios abusivos:** Personas o bots compran entradas para revenderlas mucho más caras.
2. **Entradas falsas o duplicadas:** Es fácil revender la misma entrada varias veces.

Este sistema controla mediante código que **nadie pueda revender una entrada por encima de un precio límite fijado**, y garantiza que cada entrada sea única y cambie de dueño de forma segura.

---

## Archivos del repositorio

* **`TicketSystemBasic.sol`**: Versión inicial del contrato. Permite crear eventos, comprar entradas y transferirlas sin restricciones de precio.
* **`TicketSystemAntiFraud.sol`**: Versión mejorada. Añade las siguientes reglas:
  * **Límite de precio en reventa:** El vendedor no puede poner un precio superior al porcentaje máximo permitido sobre el precio original (por ejemplo, un 110% o 120%).
  * **Comisión para el organizador:** Un pequeño porcentaje de cada reventa va al organizador del evento.
  * **Control de estado:** Cada entrada pasa por estados claros (`Válida`, `Usada`, `Cancelada`) para que no se pueda usar ni revender dos veces.
* **`Memoria_Reventa_AntiFraude.pdf`**: Documento completo con la explicación detallada del diseño, las pruebas realizadas y el análisis de seguridad.

---

## Cómo probar los contratos

1. Abre [Remix Ethereum IDE](https://remix.ethereum.org/).
2. Copia el contenido de `TicketSystemAntiFraud.sol` en un archivo nuevo.
3. Compila el contrato (versión de Solidity `^0.8.0`).
4. Ve a la pestaña **Deploy & Run Transactions** y despliega el contrato en la red de pruebas de Remix o en Sepolia.
