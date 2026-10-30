| kernel | release | profile | runs | median ms | min | max | spread |
|---|---|---|---|---|---|---|---|
| head | 7.2.0-rc4-g32e5e10b81d8-dirty | diskread | 5 | 6800 | 4720 | 20090 | 226.0% |
| head | 7.2.0-rc4-g32e5e10b81d8-dirty | forkexec | 5 | 34320 | 25070 | 42790 | 51.6% |
| head | 7.2.0-rc4-g32e5e10b81d8-dirty | pagefault | 5 | 1700 | 1440 | 12020 | 622.4% |
| pin | 7.2.0-rc4-g169b17ff3f66-dirty | diskread | 5 | 5410 | 3970 | 33830 | 551.9% |
| pin | 7.2.0-rc4-g169b17ff3f66-dirty | forkexec | 5 | 30930 | 27420 | 39940 | 40.5% |
| pin | 7.2.0-rc4-g169b17ff3f66-dirty | pagefault | 5 | 3530 | 2010 | 9310 | 206.8% |

VERDICT diskread: head 6800 ms vs pin 5410 ms -> pin lebih cepat 20.4%
VERDICT forkexec: head 34320 ms vs pin 30930 ms -> pin lebih cepat 9.9%
VERDICT pagefault: head 1700 ms vs pin 3530 ms -> pin lebih lambat 107.6%
