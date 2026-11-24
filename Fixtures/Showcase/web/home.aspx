<%@ Page Language="C#" %>
<!doctype html>
<html><body>
<asp:Label runat="server" Text="<%# Model.Name %>" />
<% if (ready) { Response.Write("Ready"); } %>
<%-- ASP.NET comment --%>
</body></html>
