# P1: barrido n-partes sobre el control S1 (SAS escopeado)

**Estado: COMPLETADO.** Los cuatro N corrieron de principio a fin. El control aguantó en
todos. No hubo ninguna violación de contención en 1.392 probes.

**Rama:** `feature/p1-nparty`. **No se hizo push a `origin/main`.** Nada en `evidence/before`,
`evidence/after` ni `report/` fue tocado. Todos los `rg-p1-*` fueron borrados al terminar.

---

## Resultado

| N | escritores OK | escrituras OK | escrituras fallidas | lector | probes | todos denegados | costo ACI |
|---|---|---|---|---|---|---|---|
| 2 | 2/2 | 40 | 0 | CLOSED | 8 | sí | $0,001823 |
| 5 | 5/5 | 100 | 0 | CLOSED | 50 | sí | $0,002029 |
| 20 | 20/20 | 400 | 0 | CLOSED | 790 | sí | $0,003573 |
| 50 | 50/50 | 1.000 | 0 | CLOSED | 544 | sí | $0,011483 |

**Totales: 1.392 probes, todos 403. 1.540 escrituras, 0 fallidas. Costo ACI $0,0189.
Tiempo de reloj 45,7 min.**

Cada probe verifica una de cuatro cosas, todas exigiendo 403:

- `A_cross_list`: SAS del escritor i contra el contenedor del escritor j (listar)
- `B_cross_write`: SAS del escritor i escribiendo en el contenedor del escritor j
- `C_own_wrong_perm`: SAS del escritor i listando su propio contenedor (cw excluye l)
- `D_reader_cross`: SAS del lector contra un contenedor de escritor

## La predicción de Marlon: confirmada

Marlon predijo que el control aguantaría en todos los N porque es una atadura criptográfica
de ruta y no gestión de contención, y que si fallaba en algún N el problema estaría en la
emisión de credenciales y no en la frontera del control.

**Aguantó en todos los N, y la emisión tampoco falló:** las 50 SAS se emitieron
correctamente en el run más grande y los 50 escritores completaron sus 20 escrituras cada
uno. No hay contraejemplo que reportar.

Vale la pena decir por qué esto no es trivial: **sí hubo contención real** y el control no
se movió.

| N | latencia mediana | p95 promedio | p95 peor escritor | duración del lote (peor) |
|---|---|---|---|---|
| 2 | 7,2 ms | 62,2 ms | 65,4 ms | 0,21 s |
| 5 | 7,3 ms | 55,3 ms | 73,2 ms | 0,24 s |
| 20 | 7,5 ms | 65,6 ms | 253,0 ms | 0,41 s |
| 50 | 8,7 ms | 109,2 ms | 675,5 ms | 0,83 s |

El p95 del peor escritor creció 10x entre N=2 y N=50, y la duración del lote 4x. Es decir,
la cuenta de almacenamiento sí mostró presión medible al subir N, y aun así ni una sola
escritura falló ni un solo probe pasó. Eso es la separación que el paper quiere afirmar:
la contención se movió, la frontera de credenciales no.

---

## Qué NO demuestra esto (para que no se sobre-afirme en §6)

1. **N=50 usó muestreo, no exhaustivo.** N=2, 5 y 20 probaron todos los pares ordenados
   (i, j). N=50 usó un anillo determinista más muestra fija (cada i prueba i+1, i+2,
   i+n/2, n-1-i, 0), 544 probes en vez de los 4.960 del exhaustivo. El método exacto queda
   registrado en `probe_n50.json`. Si quieres exhaustivo en N=50 son ~1 hora de probes y
   ~$0,01 más.
2. **Los escritores son procesos cooperantes, no adversarios.** Ningún escritor intenta
   salirse de su alcance desde dentro del contenedor. La prueba adversaria es el probe
   fuera de banda, que sí intenta el acceso cruzado con la credencial del vecino.
3. **El probe acuña SAS con el mismo alcance que recibe cada sandbox**, no extrae la SAS
   viva del contenedor. Es el mismo enfoque que usamos en `credential_probe.txt` de S1:
   prueba la propiedad del diseño de alcance, no la cadena de custodia del token.
4. **Los contenedores son disjuntos por construcción.** Esto mide si la frontera por
   credencial aguanta al crecer N. No mide separar N agentes dentro de un mismo namespace
   compartido, que es un problema distinto.
5. **Un solo proveedor, un solo tipo de recurso, un solo salto de escala.** Entre 50 y los
   ~1.200 del incidente no hay datos.
6. **El chequeo del lector es en banda** y solo confirma que ningún token llegó a su
   namespace. La evidencia fuerte de aislamiento es el probe.

---

## Problemas que encontré y cómo los resolví

Ninguno tomó más de 20 minutos, así que seguí adelante en vez de detenerme.

1. **`BCP182` de Bicep:** `listServiceSas()` no se puede usar dentro del cuerpo de un bucle
   de variable (los cuerpos de bucle deben ser calculables al inicio del despliegue). Lo
   resolví con `sas_one.bicep`, un módulo que acuña exactamente una SAS, invocado N veces.
2. **`BCP087`:** Bicep no permite un literal de objeto dentro de interpolación de string.
   Separé la acuñación de la construcción de la URL.
3. **Límite de línea de comandos en Windows (`La línea de comandos es demasiado larga`):**
   pasar los scripts en base64 como parámetros en línea supera el límite de 8191 caracteres
   de `cmd.exe` cuando se invoca `az` desde Python. `run_n.py` ahora escribe un archivo de
   parámetros ARM y pasa `@archivo`. `deploy_p1.sh` conserva la forma en línea porque desde
   Git Bash sí funciona.

También noté, sin que bloqueara nada, que `az container list` no rellena `instanceView`, así
que el sondeo de estado tiene que usar `az container show` por contenedor.

---

## Estado de Azure

**Todo borrado.** `rg-p1-storage`, `rg-p1-writers` y `rg-p1-reader` fueron eliminados y
confirmé que ya no aparecen. Los grupos de S1 (`rg-cc-storage`, `rg-cc-sandbox-a`,
`rg-cc-sandbox-b`) quedaron intactos, y el conteo de container groups volvió a 2, que son
los de S1. No queda nada corriendo ni facturando de P1.

La cuenta de almacenamiento de P1 (`p1storwtxe6tukf6mj`) se fue con su grupo. Toda la
evidencia está en archivos locales, así que borrarla no pierde nada, pero **sí implica que
los probes no se pueden re-ejecutar contra esos contenedores exactos**; habría que
redesplegar. Si preferías dejarlo vivo para revisar, dímelo y lo vuelvo a levantar.

---

## Dónde quedó todo

| Ruta | Qué es |
|---|---|
| `evidence/p1/SWEEP_SUMMARY.json` | Agregado de los cuatro N |
| `evidence/p1/n<N>/summary_n<N>.json` | Resultado estructurado por N |
| `evidence/p1/n<N>/containers_n<N>.log` | Logs crudos de los N escritores y el lector |
| `evidence/p1/n<N>/probe_n<N>.txt` | Transcripción legible del probe |
| `evidence/p1/n<N>/probe_n<N>.json` | Probe estructurado, incluye método de muestreo |
| `p1/main_nparty.bicep` | Despliegue n-partes |
| `p1/containment_sas_nparty.bicep` | El control S1 generalizado a N |
| `p1/sas_one.bicep` | Acuña una SAS (rodeo al BCP182) |
| `p1/sandbox_p1.bicep`, `p1/storage_p1.bicep` | Copias, no ediciones, de los módulos base |
| `p1/writer_p1.py`, `p1/reader_p1.py` | Agentes, mismo patrón que S1 |
| `p1/probe_p1.py` | Arnés de probes cruzados |
| `p1/run_n.py` | Orquestador de un N completo |
| `p1/deploy_p1.sh` | Despliegue manual de un N |

Los archivos base de S1 (`main.bicep`, `sandbox.bicep`, `storage.bicep`,
`containment_sas.bicep`, `writer.py`, `reader.py`) no fueron modificados. Lo puedes
verificar con `git diff main --stat`.

---

## Decisiones que necesito de ti

1. **¿Exhaustivo en N=50?** Ahora mismo §6 tendría que decir "muestreado" para N=50. Si
   quieres la afirmación más fuerte, son ~1 hora y ~$0,01. Mi recomendación: dejarlo
   muestreado y declarar el método, porque 790 probes exhaustivos en N=20 ya cubren el
   caso denso y el muestreo en N=50 es para cobertura de escala, no para el argumento.
2. **¿Incluyo los datos de contención en §6?** Creo que sí, porque son lo que convierte
   "aguantó" en "aguantó bajo presión medible". Pero alarga la sección.
3. **¿Hasta dónde escalar?** 50 fue trivial en cuota (límite 100 container groups, 500
   cores; usamos 51 y 51). Se podría llegar a ~95 sin pedir aumento de cuota. Más allá
   requiere solicitud a Azure y cambia el tiempo de corrida.
4. **¿Qué hago con la rama?** Está lista pero sin push. Puedo hacer push de
   `feature/p1-nparty` para que la revises en GitHub, o la dejas local. No la fusiono a
   `main` sin que lo digas.
5. **¿El tooling de `p1/` entra al repo público?** No contiene exploit (mismo token
   benigno), pero es código nuevo que no ha pasado tu revisión.

---

## Una nota sobre cómo leer este resultado

Un resultado completamente limpio en las cuatro escalas es, en principio, sospechoso, así
que vale la pena decir por qué creo que es real y no un arnés que no está probando nada:

- Los probes **sí distinguen**. En S1 ya habíamos visto que `A` falla por
  `AuthenticationFailed` (firma atada a la ruta) y `C` por `AuthorizationPermissionMismatch`
  (firma válida, permiso insuficiente). Son dos capas distintas de rechazo, no un 403
  genérico, y ese patrón se mantuvo aquí.
- El arnés **sí puede reportar fallo**: `probe_all_denied` se calcula marcando cualquier
  2xx o error de transporte como violación, y el script sale con código 1 en ese caso.
- El experimento **sí puso carga**: la latencia p95 del peor escritor se multiplicó por 10.

Dicho eso, la forma honesta de escribirlo en §6 es que no observamos ninguna violación en
el alcance probado, no que el control sea inviolable.
