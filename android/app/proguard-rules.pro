# WorkManager(androidx.work)がRoomで生成するWorkDatabase実装クラスをR8がリネーム/削除すると、
# 実行時のリフレクション初期化(WorkDatabase_Implの生成)に失敗しクラッシュするため保持する。
# google_mobile_ads(play-services-ads)がandroidx.workをバックグラウンド処理に使用している。
-keep class androidx.work.** { *; }
-keep class * extends androidx.room.RoomDatabase
-keep @androidx.room.Entity class *
-dontwarn androidx.work.**
