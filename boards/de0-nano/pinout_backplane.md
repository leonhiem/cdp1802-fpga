# DIN41617 Backplane Connector — 31-pin, male (angled)

Note:  This is NOT an A-C or A-B-C connector, just 1 to 31 !


| Pin | Signal name | Direction (card's view) | Domain (5V / GND / other) | Notes | CDP1802
|-----|-------------|-------------------------|---------------------------|-------|--------
|  1  | +5V power   |        in               |   5V powersupply          |       |
|  2  | LC 50Hz     |        in               |   5V signal               |  *1   |
|  3  | nINT        |        in               |   5V signal               |  *2   | yes, interrupt
|  4  | nMWR        |        out              |   5V signal               |       | yes, mem write
|  5  | TPA         |        out              |   5V signal               |       | yes, TPA
|  6  | nMRD        |        out              |   5V signal               |       | yes, mem read
|  7  | TPB         |        out              |   5V signal               |       | yes, TPB
|  8  | D7          |        inout            |   5V signal               |  *1   | yes, data
|  9  | A7/A15      |        out              |   5V signal               |       | yes, address
|  10 | D6          |        inout            |   5V signal               |  *1   | yes, data
|  11 | A6/A14      |        out              |   5V signal               |       | yes, address
|  12 | D5          |        inout            |   5V signal               |  *1   | yes, data
|  13 | A5/A13      |        out              |   5V signal               |       | yes, address
|  14 | D4          |        inout            |   5V signal               |  *1   | yes, data
|  15 | A4/A12      |        out              |   5V signal               |       | yes, address
|  16 | D3          |        inout            |   5V signal               |  *1   | yes, data
|  17 | A3/A11      |        out              |   5V signal               |       | yes, address
|  18 | D2          |        inout            |   5V signal               |  *1   | yes, data
|  19 | A2/A10      |        out              |   5V signal               |       | yes, address
|  20 | D1          |        inout            |   5V signal               |  *1   | yes, data
|  21 | A1/A9       |        out              |   5V signal               |       | yes, address
|  22 | D0          |        inout            |   5V signal               |  *1   | yes, data
|  23 | A0/A8       |        out              |   5V signal               |       | yes, address
|  24 | nEF1        |        in               |   5V signal               |  *1   | yes, EF input
|  25 | n2          |        out              |   5V signal               |       | yes, out address
|  26 | nEF2        |        in               |   5V signal               |  *1   | yes, EF input
|  27 | n1          |        out              |   5V signal               |       | yes, out address
|  28 | nEF3        |        in               |   5V signal               |  *1   | yes, EF input
|  29 | n0          |        out              |   5V signal               |       | yes, out address
|  30 | Q           |        out              |   5V signal               |       | yes, Q
|  31 | GND         |        in               |   GND powersupply         |       |

*1: needs 10k pullup to +5V

*2: needs 10k pullup to +5V and 100pF to GND

All signals are CDP1802 signals except pin 1,2 and 31

All signals must go through the level shifter, except pin 1 and 31. In order to connect DE0-nano to the backplane

