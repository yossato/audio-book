"""
オーディオブック ビューアアプリ (PyQt6)

使い方:
    python viewer/app.py --book book.json
"""

import argparse
import json
import sys
import wave
from pathlib import Path

from PyQt6.QtCore import Qt, QTimer, QUrl
from PyQt6.QtGui import QPixmap, QPainter, QColor, QPen, QFont
from PyQt6.QtMultimedia import QMediaPlayer, QAudioOutput
from PyQt6.QtWidgets import (
    QApplication,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QPushButton,
    QSlider,
    QVBoxLayout,
    QWidget,
)


class PageView(QLabel):
    """画像 + バウンディングボックスオーバーレイを表示するウィジェット"""

    def __init__(self):
        super().__init__()
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.original_pixmap = None
        self.blocks = []
        self.active_block_id = -1
        self.scale = 1.0
        self.offset_x = 0
        self.offset_y = 0
        self._click_callback = None

    def set_click_callback(self, callback):
        self._click_callback = callback

    def load_page(self, image_path: str, blocks: list):
        self.original_pixmap = QPixmap(image_path)
        self.blocks = blocks
        self.active_block_id = -1
        self._render()

    def set_active_block(self, block_id: int):
        if self.active_block_id != block_id:
            self.active_block_id = block_id
            self._render()

    def _render(self):
        if self.original_pixmap is None:
            return

        # ウィジェットサイズに合わせてスケーリング
        available_w = self.width() if self.width() > 100 else 800
        available_h = self.height() if self.height() > 100 else 1000
        scaled = self.original_pixmap.scaled(
            available_w, available_h,
            Qt.AspectRatioMode.KeepAspectRatio,
            Qt.TransformationMode.SmoothTransformation,
        )

        self.scale = scaled.width() / self.original_pixmap.width()
        # オフセット計算（中央揃え用）
        self.offset_x = (available_w - scaled.width()) // 2
        self.offset_y = (available_h - scaled.height()) // 2

        canvas = QPixmap(available_w, available_h)
        canvas.fill(QColor(240, 240, 240))

        painter = QPainter(canvas)
        painter.drawPixmap(self.offset_x, self.offset_y, scaled)

        for block in self.blocks:
            x1, y1, x2, y2 = block["bbox"]
            sx1 = int(x1 * self.scale) + self.offset_x
            sy1 = int(y1 * self.scale) + self.offset_y
            sw = int((x2 - x1) * self.scale)
            sh = int((y2 - y1) * self.scale)

            if block["id"] == self.active_block_id:
                # アクティブ: 半透明の黄色ハイライト
                painter.fillRect(sx1, sy1, sw, sh, QColor(255, 255, 0, 80))
                pen = QPen(QColor(255, 165, 0), 2)
            else:
                # 非アクティブ: 薄い枠のみ
                pen = QPen(QColor(100, 100, 255, 60), 1)

            painter.setPen(pen)
            painter.drawRect(sx1, sy1, sw, sh)

        painter.end()
        self.setPixmap(canvas)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._render()

    def mousePressEvent(self, event):
        if event.button() != Qt.MouseButton.LeftButton:
            return
        if self.original_pixmap is None:
            return

        # クリック座標 → 元画像の座標に変換
        click_x = (event.position().x() - self.offset_x) / self.scale
        click_y = (event.position().y() - self.offset_y) / self.scale

        for block in self.blocks:
            x1, y1, x2, y2 = block["bbox"]
            if x1 <= click_x <= x2 and y1 <= click_y <= y2:
                if self._click_callback:
                    self._click_callback(block)
                return


class AudioBookViewer(QMainWindow):
    def __init__(self, book_path: str):
        super().__init__()
        self.setWindowTitle("Audio Book Viewer")
        self.setMinimumSize(900, 700)

        with open(book_path, encoding="utf-8") as f:
            self.book = json.load(f)

        self.current_page_idx = 0
        self.page_duration = 0.0

        # 音声プレーヤー
        self.player = QMediaPlayer()
        self.audio_output = QAudioOutput()
        self.player.setAudioOutput(self.audio_output)
        self.audio_output.setVolume(1.0)

        # タイマーでハイライト更新
        self.timer = QTimer()
        self.timer.setInterval(50)  # 50ms ごとに更新
        self.timer.timeout.connect(self._update_highlight)

        self.player.playbackStateChanged.connect(self._on_playback_state_changed)

        self._build_ui()
        self._load_page(0)

    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)

        # ページ画像表示
        self.page_view = PageView()
        self.page_view.set_click_callback(self._on_block_clicked)
        layout.addWidget(self.page_view, stretch=1)

        # コントロールバー
        controls = QHBoxLayout()

        self.btn_prev = QPushButton("< 前ページ")
        self.btn_prev.clicked.connect(self._prev_page)
        controls.addWidget(self.btn_prev)

        self.btn_play = QPushButton("再生")
        self.btn_play.clicked.connect(self._toggle_play)
        controls.addWidget(self.btn_play)

        self.btn_next = QPushButton("次ページ >")
        self.btn_next.clicked.connect(self._next_page)
        controls.addWidget(self.btn_next)

        layout.addLayout(controls)

        # シークバー
        seek_layout = QHBoxLayout()
        self.slider = QSlider(Qt.Orientation.Horizontal)
        self.slider.setRange(0, 1000)
        self.slider.sliderPressed.connect(self._on_slider_pressed)
        self.slider.sliderReleased.connect(self._on_slider_released)
        seek_layout.addWidget(self.slider, stretch=1)

        self.time_label = QLabel("00:00 / 00:00")
        self.time_label.setFont(QFont("Menlo", 12))
        seek_layout.addWidget(self.time_label)

        layout.addLayout(seek_layout)

        # ページ情報
        self.page_label = QLabel()
        self.page_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(self.page_label)

    def _load_page(self, page_idx: int):
        if page_idx < 0 or page_idx >= len(self.book["pages"]):
            return

        self.player.stop()
        self.timer.stop()
        self.current_page_idx = page_idx
        page = self.book["pages"][page_idx]

        # 画像とブロックを読み込み
        self.page_view.load_page(page["image_path"], page["blocks"])

        # 音声を読み込み
        audio_path = page.get("audio_path")
        if audio_path and Path(audio_path).exists():
            self.player.setSource(QUrl.fromLocalFile(audio_path))
            self.page_duration = self._get_wav_duration(audio_path)
        else:
            self.page_duration = 0.0

        # UI更新
        total = len(self.book["pages"])
        self.page_label.setText(f"ページ {page_idx + 1} / {total}")
        self.btn_prev.setEnabled(page_idx > 0)
        self.btn_next.setEnabled(page_idx < total - 1)
        self.btn_play.setText("再生")
        self._update_time_label(0)
        self.slider.setValue(0)

    def _get_wav_duration(self, path: str) -> float:
        try:
            with wave.open(path, "r") as w:
                return w.getnframes() / w.getframerate()
        except Exception:
            return 0.0

    def _toggle_play(self):
        if self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState:
            self.player.pause()
            self.timer.stop()
            self.btn_play.setText("再生")
        else:
            self.player.play()
            self.timer.start()
            self.btn_play.setText("一時停止")

    def _on_playback_state_changed(self, state):
        if state == QMediaPlayer.PlaybackState.StoppedState:
            self.timer.stop()
            self.btn_play.setText("再生")
            # ページ末尾で自動的に次ページへ
            if self.player.position() > 0 and self.current_page_idx < len(self.book["pages"]) - 1:
                self._next_page()
                self._toggle_play()  # 自動再生

    def _update_highlight(self):
        pos_ms = self.player.position()
        pos_sec = pos_ms / 1000.0

        page = self.book["pages"][self.current_page_idx]
        active_id = -1
        for block in page["blocks"]:
            start = block.get("audio_start")
            end = block.get("audio_end")
            if start is not None and end is not None:
                if start <= pos_sec < end:
                    active_id = block["id"]
                    break

        self.page_view.set_active_block(active_id)
        self._update_time_label(pos_sec)

        # スライダー更新（ドラッグ中でなければ）
        if not self.slider.isSliderDown() and self.page_duration > 0:
            self.slider.setValue(int(pos_sec / self.page_duration * 1000))

    def _update_time_label(self, current_sec: float):
        def fmt(s):
            m = int(s) // 60
            sec = int(s) % 60
            return f"{m:02d}:{sec:02d}"
        self.time_label.setText(f"{fmt(current_sec)} / {fmt(self.page_duration)}")

    def _on_block_clicked(self, block: dict):
        start = block.get("audio_start")
        if start is not None:
            self.player.setPosition(int(start * 1000))
            if self.player.playbackState() != QMediaPlayer.PlaybackState.PlayingState:
                self.player.play()
                self.timer.start()
                self.btn_play.setText("一時停止")

    def _on_slider_pressed(self):
        pass

    def _on_slider_released(self):
        if self.page_duration > 0:
            ratio = self.slider.value() / 1000.0
            pos_ms = int(ratio * self.page_duration * 1000)
            self.player.setPosition(pos_ms)

    def _prev_page(self):
        self._load_page(self.current_page_idx - 1)

    def _next_page(self):
        self._load_page(self.current_page_idx + 1)


def main():
    parser = argparse.ArgumentParser(description="Audio Book Viewer")
    parser.add_argument("--book", type=str, required=True, help="book.json のパス")
    args = parser.parse_args()

    app = QApplication(sys.argv)
    viewer = AudioBookViewer(args.book)
    viewer.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
