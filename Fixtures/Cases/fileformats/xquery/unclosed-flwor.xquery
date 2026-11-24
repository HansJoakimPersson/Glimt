for $item in doc("items.xml")//item
where $item/@price > 10
return <entry>{ $item/title
