-- Ad-hoc check in SSMS: C: size and free space for assets matching a name pattern.
-- Set @NamePattern and @MinFreeGB, then run. Same math as Get-VmmLansweeperDiskSpace.
DECLARE @NamePattern NVARCHAR(128) = N'<SERVER-PREFIX>%';   -- e.g. N'SRV-APP-%'
DECLARE @MinFreeGB   DECIMAL(10,1) = 20;

SELECT
    a.AssetName,
    d.Caption AS Drive,
    CAST(CAST(d.Size      AS DECIMAL(20,0)) / 1073741824.0 AS DECIMAL(10,1)) AS SizeGB,
    CAST(CAST(d.Freespace AS DECIMAL(20,0)) / 1073741824.0 AS DECIMAL(10,1)) AS FreeGB,
    CASE WHEN CAST(d.Freespace AS DECIMAL(20,0)) / 1073741824.0 >= @MinFreeGB THEN 'OK' ELSE 'LOW' END AS Status,
    a.Lastseen AS LastScanned
FROM tblAssets a
JOIN tblDiskdrives d ON d.AssetID = a.AssetID
WHERE a.AssetName LIKE @NamePattern
  AND a.LastScanned IS NOT NULL
  AND d.Caption = 'C:'
ORDER BY a.AssetName;
