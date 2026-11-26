-- The tour's only logic: a way out that does not depend on the scene's springs. Once it is leaving (Skip, Escape, Done, a click outside the
-- card), it is gone three seconds later at the latest; and it never stays more than ten minutes.
on("fact:leaving", function(v)
    if v == true then after(3000, function() emit("gone") end) end
end)
after(600000, function() emit("gone") end)
