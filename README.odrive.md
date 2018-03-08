# Show how to access a Sharepoint group drive in Office 365 business or education


When we click "sync" in a Sharepoint groups Documents page we get an
"odopen" URL, example:

odopen://sync?userId=97858aa6%2Dcd6a%2D4025%2Da6ee%2D29ba80bcbec5&siteId=%7B0936e7d2%2D1285%2D4c54%2D81f9%2D55e9c8b8613b%7D&webId=%7B345db3b7%2D1ebb%2D484f%2D85e3%2D31c785278051%7D&webTitle=FFCCTT%5FIET&listId=%7BA3913FAC%2D26F8%2D4436%2DA9F6%2DAA6B44776343%7D&listTitle=Documentos&userEmail=georg%2Elehner%40ucan%2Eedu%2Eni&listTemplateTypeId=101&webUrl=https%3A%2F%2Fucanedu%2Esharepoint%2Ecom%2Fsites%2FFFCCTT%5FIET&webLogoUrl=%2Fsites%2FFFCCTT%5FIET%2F%5Fapi%2FGroupService%2FGetGroupImage%3Fid%3D%270e6466dc%2D1d90%2D41b0%2D9c9d%2Df6a818721435%27%26hash%3D636549326262064339&isSiteAdmin=1&webTemplate=64&onPrem=0&scope=OPENLIST"

Urldecoded parameters:

	userId=97858aa6-cd6a-4025-a6ee-29ba80bcbec5
	siteId={0936e7d2-1285-4c54-81f9-55e9c8b8613b}
	webId={345db3b7-1ebb-484f-85e3-31c785278051}
	webTitle=FFCCTT_IET
	listId={A3913FAC-26F8-4436-A9F6-AA6B44776343}
	listTitle=Documentos
	userEmail=georg.lehner@ucan.edu.ni
	listTemplateTypeId=101
	webUrl=https://ucanedu.sharepoint.com/sites/FFCCTT_IET
	webLogoUrl=/sites/FFCCTT_IET/_api/GroupService/GetGroupImage?id='0e6466dc-1d90-41b0-9c9d-f6a818721435'&hash=636549326262064339
	isSiteAdmin=1
	webTemplate=64
	onPrem=0
	scope=OPENLIST

In the following we refer to these parameters with e.g. $userId,
wherever there are enclosing braces {} you have to strip them off.


1- Get site drive-id with:

	GET https://graph.microsoft.com/v1.0/sites/$host,$SiteId,$webId/lists/$listId/drive

   Example:

	GET https://graph.microsoft.com/v1.0/sites/ucanedu.sharepoint.com,0936e7d2-1285-4c54-81f9-55e9c8b8613b,345db3b7-1ebb-484f-85e3-31c785278051/lists/A3913FAC-26F8-4436-A9F6-AA6B44776343/drive

   where $host is the hostname in $webUrl.

   -> b!0uc2CYUSVEyB-VXpyLhhO7ezXTS7Hk9IheMxx4UngFGsP5Gj-CY2RKn2qmtEd2ND

2- Get root folder id via drive-id

	GET https://graph.microsoft.com/v1.0/drives/$drive-id/root

   Example:

	GET https://graph.microsoft.com/v1.0/drives/b!0uc2CYUSVEyB-VXpyLhhO7ezXTS7Hk9IheMxx4UngFGsP5Gj-CY2RKn2qmtEd2ND/root

   -> 016SJBHDN6Y2GOVW7725BZO354PWSELRRZ

  But this one you already knew.
