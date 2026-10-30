| kernel | release | profile | runs | median ms | min | max | spread |
|---|---|---|---|---|---|---|---|
| head | 7.2.0-rc4-g32e5e10b81d8-dirty | diskread | 3 | 5580 | 3410 | 127150 | 2217.6% |
| head | 7.2.0-rc4-g32e5e10b81d8-dirty | forkexec | 3 | 43430 | 28220 | 51050 | 52.6% |
| head | 7.2.0-rc4-g32e5e10b81d8-dirty | pagefault | 3 | 1180 | 1120 | 3760 | 223.7% |
| pin | 7.2.0-rc4-g169b17ff3f66-dirty | diskread | 3 | 6169 | 5010 | 13040 | 130.2% |
| pin | 7.2.0-rc4-g169b17ff3f66-dirty | forkexec | 4 | 44625 | 35160 | 50180 | 33.7% |
| pin | 7.2.0-rc4-g169b17ff3f66-dirty | pagefault | 4 | 1545 | 1400 | 2620 | 79.0% |

VERDICT diskread: head 5580 ms vs pin 6169 ms -> pin lebih lambat 10.6%
VERDICT forkexec: head 43430 ms vs pin 44625 ms -> setara (selisih <5%)
VERDICT pagefault: head 1180 ms vs pin 1545 ms -> pin lebih lambat 30.9%
