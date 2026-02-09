from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import argparse

import numpy as np
import pandas as pd
import speckit as sp
from speckit.dsp import frequency2phase
import matplotlib.pyplot as plt


DEFAULT_FS = 14.901161193847656
COLS = [
    "cnts",
    "PIR_0",
    "PIR_1",
    "Q_0",
    "Q_1",
    "I_0",
    "I_1",
    "Piezo_0",
    "Piezo_1",
    "Temperature_0",
    "Temperature_1",
    "FreqErr_0",
    "FreqErr_1",
]


@dataclass(frozen=True)
class PhaseSpectra:
    ch1: sp.Spectrum | None
    ch2: sp.Spectrum | None
    diff: sp.Spectrum | None


def _normalize_header(columns: list[str]) -> list[str]:
    return ["I_1" if col == "I-1" else col for col in columns]


def _find_header(path: Path) -> tuple[list[str], int]:
    with path.open("r", encoding="utf-8") as handle:
        for idx, line in enumerate(handle):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            return stripped.split(), idx
    return [], -1


def load_data(path: Path) -> pd.DataFrame:
    header, header_idx = _find_header(path)
    if header:
        header = _normalize_header(header)
        return pd.read_csv(path, skiprows=header_idx + 1, delimiter=" ", names=header)
    return pd.read_csv(path, skiprows=5, delimiter=" ", names=COLS)


def _has_channel(df: pd.DataFrame, channel: int) -> bool:
    column = f"PIR_{channel}"
    return column in df.columns and df[column].notna().any()


def add_phase_columns(df: pd.DataFrame, fs: float) -> pd.DataFrame:
    df = df.copy()
    has_ch1 = _has_channel(df, 0)
    has_ch2 = _has_channel(df, 1)

    if has_ch1:
        df["phase_0"] = frequency2phase(df.PIR_0, fs)
    if has_ch2:
        df["phase_1"] = frequency2phase(df.PIR_1, fs)
    if has_ch1 and has_ch2:
        df["PIR_01"] = df["PIR_0"] - df["PIR_1"]
        df["phase_01"] = frequency2phase(df.PIR_01, fs)
        df["phase_01_alt"] = df["phase_0"] - df["phase_1"]
    return df


def compute_phase_spectra(df: pd.DataFrame, fs: float) -> PhaseSpectra:
    ch1 = sp.compute_spectrum(df.phase_0, fs=fs) if "phase_0" in df else None
    ch2 = sp.compute_spectrum(df.phase_1, fs=fs) if "phase_1" in df else None
    diff = sp.compute_spectrum(df.phase_01, fs=fs) if "phase_01" in df else None
    if ch1 is None and ch2 is None:
        raise ValueError("No PIR_0 or PIR_1 data found in input file.")
    return PhaseSpectra(ch1=ch1, ch2=ch2, diff=diff)


def lisa_req(freq: np.ndarray, level: float, corner: float) -> np.ndarray:
    return level * np.sqrt(1 + ((corner / freq) ** 4))


def _reference_spectrum(phase_spectra: PhaseSpectra) -> sp.Spectrum:
    if phase_spectra.ch1 is not None:
        return phase_spectra.ch1
    if phase_spectra.ch2 is not None:
        return phase_spectra.ch2
    if phase_spectra.diff is not None:
        return phase_spectra.diff
    raise ValueError("No spectra available to plot.")


def plot_phase_asd(phase_spectra: PhaseSpectra) -> tuple[plt.Figure, plt.Axes]:
    fig, ax = plt.subplots(figsize=(4, 3), dpi=150)

    if phase_spectra.ch1 is not None:
        phase_spectra.ch1.plot(which="asd", ax=ax, c="b", label="Ch1 phase")
    if phase_spectra.ch2 is not None:
        phase_spectra.ch2.plot(which="asd", ax=ax, c="cyan", ls="--", label="Ch2 phase")
    if phase_spectra.diff is not None:
        phase_spectra.diff.plot(which="asd", ax=ax, c="r", label="Ch1-Ch2 phase")

    ref = _reference_spectrum(phase_spectra)
    ax.set_xlim(ref.f[0], ref.f[-1])
    ax.loglog(
        ref.f,
        lisa_req(ref.f, 2 * np.pi * np.sqrt(2) * 1e-6, 2e-3),
        label="Picometers",
        c="k",
    )

    ax.grid(ls="--", c="lightgray", alpha=1)
    ax.legend(framealpha=1, edgecolor="k")
    ax.set_ylabel(r"ASD [rad/$\sqrt{\rm Hz}$]")
    return fig, ax


def _readout_dir() -> Path:
    return Path(__file__).resolve().parent


def _latest_readout_folder() -> Path | None:
    rd = _readout_dir()
    if not rd.is_dir():
        return None
    subdirs = [p for p in rd.iterdir() if p.is_dir() and not p.name.startswith(".")]
    if not subdirs:
        return None
    return max(subdirs, key=lambda p: p.name)


def _data_file_in_folder(folder: Path) -> Path | None:
    named = folder / f"{folder.name}_data.txt"
    if named.exists():
        return named
    default = folder / "data.txt"
    return default if default.exists() else None


_SAVE_NOT_GIVEN = object()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plot phase ASD for available channels."
    )
    parser.add_argument(
        "--data",
        type=Path,
        default=None,
        help="Path to data file. If not set, use latest run folder in readout/.",
    )
    parser.add_argument(
        "--fs",
        type=float,
        default=DEFAULT_FS,
        help="Sample rate in Hz.",
    )
    parser.add_argument(
        "--save",
        nargs="?",
        const=None,
        default=_SAVE_NOT_GIVEN,
        type=lambda x: Path(x) if x is not None else None,
        help="Save plot: no argument → same name as data file with .pdf; or give path.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.data is None:
        latest = _latest_readout_folder()
        if latest is None:
            raise SystemExit("No run folders found in readout/.")
        data_path = _data_file_in_folder(latest)
        if data_path is None:
            raise SystemExit(
                f"No data file found in {latest} "
                f"(looked for {latest.name}_data.txt and data.txt)."
            )
        if args.save is _SAVE_NOT_GIVEN:
            save_path = latest / f"{latest.name}_data.pdf"
        elif args.save is None:
            save_path = data_path.with_suffix(".pdf")
        else:
            save_path = args.save
    else:
        data_path = args.data
        if args.save is _SAVE_NOT_GIVEN:
            save_path = None
        elif args.save is None:
            save_path = data_path.with_suffix(".pdf")
        else:
            save_path = args.save

    df = load_data(data_path)
    df = add_phase_columns(df, args.fs)
    phase_spectra = compute_phase_spectra(df, args.fs)
    fig, _ = plot_phase_asd(phase_spectra)

    if save_path is not None:
        fig.savefig(save_path, bbox_inches="tight")
    else:
        plt.show()


if __name__ == "__main__":
    main()
