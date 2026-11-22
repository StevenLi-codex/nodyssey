#!/usr/bin/env python3
"""Generate domain-owned native resources; not behavioral test coverage."""
from pathlib import Path
import json

ROWS = '''
browser|Browser|浏览器|瀏覽器
hosts|Image hosts|图床|圖床
provider|Provider|服务商|服務商
configuration|Configuration|配置|設定
endpoint|HTTPS endpoint|HTTPS 地址|HTTPS 位址
token|API token|API 令牌|API 權杖
fileField|File field|文件字段|檔案欄位
headerName|Header name|请求头名称|請求標頭名稱
headerValue|Header value|请求头内容|請求標頭內容
formFields|Extra form fields|额外表单字段|額外表單欄位
fieldName|Field name|字段名|欄位名稱
fieldValue|Secret field value|字段内容（保密）|欄位內容（保密）
addField|Add form field|添加表单字段|新增表單欄位
formFieldsHelp|Add one name/value pair per row. Values may contain secrets and are never displayed after saving.|每行填写一个名称与内容；可能含凭证，保存后不再显示。|每行填寫一個名稱與內容；可能含憑證，儲存後不再顯示。
urlPath|Response URL path (supports array indices)|响应 URL 路径（支持数组下标）|回應 URL 路徑（支援陣列索引）
urlPrefix|URL prefix|URL 前缀|URL 前綴
save|Save|保存|儲存
configured|Configured locally|本地配置已保存|本機設定已儲存
notConfigured|Not configured|尚未配置|尚未設定
problem|Configuration issue|配置问题|設定問題
saveNotTest|Saving does not verify remote credentials. Select this host before browsing or uploading.|保存不代表远端凭证有效。浏览或上传前需选用此图床。|儲存不代表遠端憑證有效。瀏覽或上傳前需選用此圖床。
selected|Current upload host|当前上传图床|目前上傳圖床
selectHost|Use this host|选用此图床|選用此圖床
testBrowse|Test connection and browse|测试连接并浏览|測試連線並瀏覽
testingConnection|Testing connection…|正在测试连接…|正在測試連線…
connectionSucceeded|Connection successful|连接成功|連線成功
remoteImageDeleted|Image deleted from the host|图片已从图床删除|圖片已從圖床刪除
uploadOnly|This provider supports uploading only; no remote listing, deletion, or non-upload connection test is available.|此服务商仅支持上传，不支持远端图库、删除或不上传的连接测试。|此服務商僅支援上傳，不支援遠端圖庫、刪除或不上傳的連線測試。
disconnect|Disconnect|断开连接|中斷連線
clearSecrets|Clear the selected saved credentials?|清除所选已保存凭证？|清除所選已儲存憑證？
disconnectConfirm|Remove this host’s stored connection credentials?|移除此图床已保存的连接凭证？|移除此圖床已儲存的連線憑證？
saved|Saved and read back|已保存并重新读取|已儲存並重新讀取
preserveSaved|Keep saved value ••••••|保留已保存值 ••••••|保留已儲存值 ••••••
unchanged|Leave unchanged|保持不变|保持不變
replace|Replace|替换|取代
clear|Clear saved value|清除已保存值|清除已儲存值
gifOnly|GIF only|仅显示 GIF|僅顯示 GIF
select|Select|选择|選取
view|View image|查看图片|檢視圖片
copyShare|Copy or share link|复制或分享链接|複製或分享連結
delete|Delete|删除|刪除
noImages|No uploaded images|暂无已上传图片|尚無已上傳圖片
uploaded|Uploaded images|已上传图片|已上傳圖片
close|Close|关闭|關閉
addSelected|Add selected|添加所选|新增所選
refresh|Refresh|刷新|重新整理
deleteRemoteConfirm|Permanently delete this image from the host? Existing links may stop working.|从图床永久删除此图片？已发布的链接可能失效。|從圖床永久刪除此圖片？已發佈的連結可能失效。
groups|Sticker groups|表情分组|表情群組
hidden|Hidden from picker|在面板中隐藏|在面板中隱藏
addStickers|Add stickers|添加表情|新增表情
subscriptions|GitHub subscriptions|GitHub 订阅|GitHub 訂閱
probeMine|Check my sticker links|检测我的表情链接|檢查我的表情連結
backup|Backup|备份|備份
exportBackup|Export backup|导出备份|匯出備份
importBackup|Import backup|导入备份|匯入備份
backupHelp|Backups contain stickers and subscriptions, never image-host or proxy credentials.|备份包含表情与订阅，不包含图床或代理凭证。|備份包含表情與訂閱，不包含圖床或代理憑證。
importedStickers|Imported stickers|已导入表情|已匯入表情
importedFolders|Imported folders|已导入文件夹|已匯入資料夾
stickers|Sticker management|表情管理|表情管理
importConfirm|Merge this backup? Subscription imports may contact GitHub. Failed repositories will be listed.|合并此备份？订阅导入可能连接 GitHub；失败的仓库会单独列出。|合併此備份？訂閱匯入可能連線 GitHub；失敗的儲存庫會個別列出。
cdn|Sticker CDN|表情 CDN|表情 CDN
custom|Custom|自定义|自訂
cdnBase|HTTPS CDN base ending in /gh/|HTTPS CDN 基址（以 /gh/ 结尾）|HTTPS CDN 基底位址（以 /gh/ 結尾）
measure|Measure selected CDN|测试所选 CDN 速度|測試所選 CDN 速度
unreachable|Unreachable; not confirmed broken|无法连接，未确认失效|無法連線，未確認失效
effective|Currently effective|当前生效|目前生效
applyUpdate|Apply update|应用更新|套用更新
changeFolders|Change folders|更换文件夹|更換資料夾
unsubscribe|Unsubscribe|取消订阅|取消訂閱
noSubscriptions|No subscriptions yet|暂无订阅|尚無訂閱
subscribe|Subscribe|订阅|訂閱
checkUpdates|Check for updates|检查更新|檢查更新
partialUpdateFailure|Some repositories could not be checked. Their errors are retained below.|部分仓库检查失败，错误保留在对应订阅中。|部分儲存庫檢查失敗，錯誤保留在對應訂閱中。
checkedUpdates|Update check finished|更新检查已完成|更新檢查已完成
unsubscribeConfirm|Remove this subscription and its folders? Your collected stickers are kept.|移除此订阅及其文件夹？已收藏到我的表情会保留。|移除此訂閱及其資料夾？已收藏到我的表情會保留。
sourceError|Subscription error|订阅错误|訂閱錯誤
uploads|Upload queue|上传队列|上傳佇列
retry|Retry|重试|重試
clearFinished|Clear completed uploads|清除已完成上传|清除已完成上傳
groupMissing|This group is empty or no longer available.|此分组为空或已不存在。|此群組為空或已不存在。
probe|Check link|检测链接|檢查連結
rename|Rename|重命名|重新命名
moveTop|Move to top|置顶|置頂
remove|Remove|移除|移除
collect|Add to my stickers|收藏到我的表情|收藏到我的表情
selectAll|Select all|全选|全選
deselectAll|Deselect all|取消全选|取消全選
removeSelected|Remove selected|移除所选|移除所選
removeBroken|Remove confirmed broken links|移除已确认坏链|移除已確認失效連結
collectSelected|Collect selected|收藏所选|收藏所選
exportLinks|Export selected links|导出所选链接|匯出所選連結
undoCollection|Undo newly added stickers|撤销本次新增表情|復原本次新增表情
removeConfirm|Remove these stickers from your collection? Remote files are not deleted.|从我的表情中移除所选？不会删除远端文件。|從我的表情中移除所選？不會刪除遠端檔案。
name|Name|名称|名稱
cancel|Cancel|取消|取消
manage|Manage stickers|管理表情|管理表情
addFrom|Add from|添加来源|新增來源
links|Links|链接|連結
upload|Upload|上传|上傳
importLinks|Import links file|导入链接文件|匯入連結檔案
preview|Preview|预览|預覽
hostSelectHelp|Browse the currently selected host. Upload-only providers have no gallery.|浏览当前选用的图床；仅上传服务商没有图库。|瀏覽目前選用的圖床；僅上傳服務商沒有圖庫。
chooseUploaded|Choose uploaded images|选择已上传图片|選取已上傳圖片
configureHost|Configure image host|配置图床|設定圖床
added|New stickers added|新增表情|新增表情
repository|GitHub repository|GitHub 仓库|GitHub 儲存庫
repositoryURL|Repository or folder URL|仓库或文件夹 URL|儲存庫或資料夾 URL
inspect|Inspect folders|读取文件夹|讀取資料夾
pinnedCommit|Inspected commit (pinned)|已读取提交（固定版本）|已讀取提交（固定版本）
truncated|GitHub truncated the tree; some folders may be missing.|GitHub 截断了目录树，部分文件夹可能缺失。|GitHub 截斷了目錄樹，部分資料夾可能缺失。
images|images|张图片|張圖片
saveFolders|Save folder selection|保存文件夹选择|儲存資料夾選擇
sourceChangedHelp|If the branch changes before saving, inspect again. Existing posted URLs stay pinned.|保存前若分支已改变，请重新读取。已发布图片链接保持固定版本。|儲存前若分支已變更，請重新讀取。已發佈圖片連結保持固定版本。
subscribed|Subscription saved|订阅已保存|訂閱已儲存
photos|Choose photos|选择照片|選取照片
imageFiles|Choose image files|选择图片文件|選取圖片檔案
keepOriginal|Keep original format and quality|保留原始格式与画质|保留原始格式與畫質
uploadHelp|Up to 20 images per selection, 64 MB per file. GIFs retain animation. Otherwise the shared preparer resizes to 2048 px / JPEG 86 when original is off. Queued uploads continue after leaving this screen.|每次最多选 20 张，每个文件最多 64 MB。GIF 保留动画；关闭原图时，普通图片由共享处理器缩放至 2048 像素、JPEG 86。离开页面后队列继续。|每次最多選 20 張，每個檔案最多 64 MB。GIF 保留動畫；關閉原圖時，一般圖片由共享處理器縮放至 2048 像素、JPEG 86。離開頁面後佇列繼續。
uploadConfirm|Upload these files to the currently selected image host? Uploaded links will be added to your stickers.|将所选文件上传至当前图床？上传链接会加入我的表情。|將所選檔案上傳至目前圖床？上傳連結會加入我的表情。
queued|Queued, not yet complete|已入队，尚未完成|已排入佇列，尚未完成
mine|My stickers|我的表情|我的表情
site:ac|AC stickers|AC 表情|AC 表情
site:yct|Onion stickers|洋葱头|洋蔥頭
site:xhj|Little yellow chicken|小黄鸡|小黃雞
fluent|Fluent emoji|Fluent 表情|Fluent 表情
NODE_IMAGE|NodeImage|NodeImage|NodeImage
LSKY_PRO|Lsky Pro|兰空图床|蘭空圖床
EASY_IMAGE|EasyImage|简单图床|簡單圖床
SMMS|SM.MS|SM.MS|SM.MS
IMGBB|ImgBB|ImgBB|ImgBB
CUSTOM|Custom endpoint|自定义接口|自訂介面
WAITING|Waiting|等待中|等待中
UPLOADING|Uploading|上传中|上傳中
DONE|Complete|已完成|已完成
FAILED|Failed|失败|失敗
Ok|Link available|链接可用|連結可用
Broken|Confirmed broken link|已确认坏链|已確認失效連結
Unreachable|Unreachable; not confirmed broken|无法连接，未确认失效|無法連線，未確認失效
NotFound|Repository not found|仓库不存在|儲存庫不存在
NoImages|No images found|未找到图片|找不到圖片
Network|Network unavailable|网络不可用|網路無法使用
Unparsable|Invalid source response|无法解析来源响应|無法解析來源回應
Http|Source HTTP error|来源 HTTP 错误|來源 HTTP 錯誤
RateLimited|GitHub rate limit; retry after reset|GitHub 限流，请等待重置|GitHub 限流，請等待重設
'''
if __name__ == "__main__":
    base = Path(__file__).resolve().parents[1] / "Nodyssey/Native/Media/Resources"
    rows = [line.split("|") for line in ROWS.strip().splitlines()]
    assert all(len(row) == 4 for row in rows)
    assert len({row[0] for row in rows}) == len(rows)
    for column, locale in enumerate(["en", "zh-Hans", "zh-Hant"], 1):
        path = base / f"{locale}.lproj/Media.strings"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(f'{json.dumps(row[0], ensure_ascii=False)} = {json.dumps(row[column], ensure_ascii=False)};' for row in rows) + "\n")
    print(f"Generated {len(rows)} keys in each of three locales")
