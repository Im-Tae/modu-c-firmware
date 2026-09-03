# MODU Firmware

MODU-C 키보드용 ZMK 펌웨어 소스입니다.

좌우 분리형이며, **왼쪽이 중심(central)** 입니다. USB 케이블은 왼쪽에 연결하고, 오른쪽은 블루투스로 왼쪽에 붙습니다.

- **키 배열은 [KEYMAP.md](KEYMAP.md) 를 보세요.** 레이어별 그림과 특수 키 설명이 있습니다.
- 키맵 원본 파일: `modu-module/boards/shields/modu/modu.keymap`
- 미리 빌드된 펌웨어는 GitHub Releases에서 배포합니다. **직접 고칠 게 없다면 빌드할 필요 없이 Releases에서 받아 쓰면 됩니다.**

---

## 펌웨어 업데이트

`.uf2` 파일을 키보드에 복사하기만 하면 됩니다. 별도 프로그램은 필요 없습니다.

**왼쪽과 오른쪽을 각각 따로** 진행해야 하고, 파일을 서로 바꿔 넣으면 동작하지 않으니 주의하세요.

### 1. 부트로더 진입

1. 업데이트할 쪽을 USB로 연결합니다. (한 번에 한쪽만)
2. 그 쪽의 **리셋 버튼을 빠르게 두 번** 누릅니다.
3. `MODU_BOOT` 라는 USB 드라이브가 나타납니다.

`MODU_BOOT` 안에 파일 3개(`CURRENT.UF2`, `INDEX.HTM`, `INFO_UF2.TXT`)가 이미 보이는데, 부트로더가 항상 만드는 파일입니다. **지우거나 건드릴 필요 없습니다.**

### 2. 복사

`MODU_BOOT` 드라이브에 `.uf2` 파일을 끌어다 놓습니다.

| 연결한 쪽 | 넣을 파일 |
|---|---|
| 왼쪽 | `modu_left.uf2` |
| 오른쪽 | `modu_right.uf2` |

복사가 끝나면 키보드가 알아서 재부팅하고 **`MODU_BOOT` 드라이브가 사라집니다.** 이게 정상이며, 성공했다는 뜻입니다. (macOS에서 "디스크를 제대로 꺼내지 않았다"는 경고가 떠도 무시해도 됩니다.)

### 3. 반대쪽도 동일하게

USB를 뽑고 반대쪽을 연결해서 같은 과정을 반복합니다.

### 업데이트 후 확인

- 좌우가 서로 못 붙으면, 양쪽에서 `MO` + `BTCLR`(레이어 그림 참고)로 블루투스를 초기화하고 다시 페어링하세요.
- 키맵만 바꿨다면 사실 **왼쪽만 업데이트해도 됩니다.** 키 해석은 중심인 왼쪽이 전담하고, 오른쪽은 눌린 위치만 전달하기 때문입니다. 그래도 양쪽 버전을 맞춰두는 편이 헷갈리지 않습니다.

---

## 빌드

키맵이나 설정을 직접 고쳤을 때만 필요합니다.

### macOS · Linux

Docker만 있으면 됩니다. Zephyr SDK를 따로 깔지 않아도 됩니다.

```bash
./build.sh
```

첫 실행은 ZMK와 Zephyr를 내려받느라 시간이 걸리고 디스크를 몇 GB 씁니다. 받은 것은 `.zmk-workspace/`에 남아서 다음 빌드부터는 훨씬 빠릅니다.

```bash
./build.sh modu_left    # 한쪽만 빌드
./build.sh --clean      # 받아둔 ZMK 워크스페이스를 지우고 처음부터
```

### Windows

`west build`가 동작하는 ZMK 개발 환경과 Zephyr SDK가 미리 준비되어 있어야 합니다.

```bat
build.bat C:\zmk\app
```

인자는 ZMK의 `app` 폴더 경로입니다. 생략하면 `C:\zmk\app`을 씁니다.

### 결과물

양쪽 모두 `outputs/` 폴더에 만들어집니다.

```
outputs/modu_left.uf2
outputs/modu_right.uf2
```

이 파일을 위의 [펌웨어 업데이트](#펌웨어-업데이트) 순서대로 복사하면 됩니다.

### 빌드가 스스로 하는 검사

빌드가 끝날 때마다 `tools/check-weak-stubs.py`가 링커 맵을 확인하고, 실패하면 거기서 멈춥니다. ZMK 버전을 올릴 때 제일 먼저 볼 곳입니다.

---

## 구성

| 경로 | 내용 |
|---|---|
| `modu-module/boards/shields/modu/` | 키맵, 매트릭스, 좌우 설정 |
| `modu-module/boards/minewsemi/ms88sf3/` | nRF52840 보드 정의 |
| `modu-module/src/alt_thumb_kscan/` | 조립 방향에 따른 엄지 키 전환 |
| `modu-module/src/led_breath/` | 상태 LED 호흡 효과 |
| `modu-module/src/os_mode/` | Mac/Windows 모드 상태를 재부팅 후에도 유지 |
| `zmk-pmw3610-driver/` | 트랙볼 센서 드라이버 |
| `tools/uf2/` | `.hex`를 `.uf2`로 바꾸는 스크립트 |
| `tools/check-weak-stubs.py` | 빌드마다 도는 검사 ([설명](#빌드가-스스로-하는-검사)) |

## License

Copyright (c) 2026 EKS Inc. · Created by Ryu

MODU 고유 소스는 비상업적 사용·수정·동일 조건 재배포만 허용됩니다.
자세한 조건은 [LICENSE](LICENSE), 외부 코드 고지는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)를 참고하세요.
