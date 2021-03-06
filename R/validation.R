#' Additional validation checks on a DataVolley file
#'
#' This function is automatically run as part of \code{read_dv} if \code{extra_validation} is greater than zero.
#' The current validation messages/checks are:
#' \itemize{
#'   \item message "Players xxx and yyy have the same player ID": player IDs should be unique, and so duplicated IDs will be flagged here
#'   \item message "The listed player is not on court in this rotation": the player making the action is not part of the current rotation. Libero players are ignored for this check
#'   \item message "Back-row player made an attack from a front-row zone": an attack starting from zones 2-4 was made by a player in the back row of the current rotation
#'   \item message "Front-row player made an attack from a back-row zone (legal, but possibly a scouting error)": an attack starting from zones 1,5-9 was made by a player in the front row of the current rotation
#'   \item message "Block by a back-row player"
#'   \item message "Winning serve not coded as an ace"
#'   \item message "Non-winning serve was coded as an ace"
#'   \item message "Serving player not in position 1"
#'   \item message "Player designated as libero was recorded making a [serve|attack|block]"
#'   \item message "Attack (which was blocked) does not have number of blockers recorded"
#'   \item message "Attack (which was followed by a block) has 'No block' recorded for number of players"
#'   \item message "Repeated row with same skill and evaluation_code for the same player"
#'   \item message "Consecutive actions by the same player"
#'   \item message "Point awarded to incorrect team following error (or \"error\" evaluation incorrect)"
#'   \item message "Point awarded to incorrect team (or [winning play] evaluation incorrect)"
#'   \item message "Scores do not follow proper sequence": one or both team scores change by more than one point at a time
#'   \item message "Visiting/Home team rotation has changed incorrectly"
#'   \item message "Player lineup did not change after substitution: was the sub recorded incorrectly?"
#'   \item message "Player lineup conflicts with recorded substitution: was the sub recorded incorrectly?"
#'   \item message "Reception type does not match serve type": the type of reception (e.g. "Jump-float serve reception" does not match the serve type (e.g. "Jump-float serve")
#'   \item message "Reception start zone does not match serve start zone"
#'   \item message "Reception end zone does not match serve end zone"
#'   \item message "Reception end sub-zone does not match serve end sub-zone"
#'   \item message "Attack type ([type]) does not match set type ([type])": the type of attack (e.g. "Head ball attack") does not match the set type (e.g. "High ball set")
#'   \item message "Block type ([type]) does not match attack type ([type])": the type of block (e.g. "Head ball block") does not match the attack type (e.g. "High ball attack")
#'   \item message "Dig type ([type]) does not match attack type ([type])": the type of dig (e.g. "Head ball dig") does not match the attack type (e.g. "High ball attack")
#' }
#' 
#' @param x datavolley: datavolley object as returned by \code{read_dv}
#' @param validation_level numeric: how strictly to check? If 0, perform no checking; if 1, only identify major errors; if 2, also return any issues that are likely to lead to misinterpretation of data; if 3, return all issues (including minor issues such as those that might have resulted from selective post-processing of compound codes)
#' @param options list: named list of options that control optional validation behaviour. Valid entries are:
#' \itemize{
#'   \item setter_tip_codes character: vector of attack codes that represent setter tips (or other attacks that a back-row player can validly make from a front-row position). If you code setter tips as attacks, and don't want such attacks to be flagged as an error when made by a back-row player in a front-row zone, enter the setter tip attack codes here. e.g. \code{options=list(setter_tip_codes=c("PP","XY"))}
#' }
#' @param file_type string: "indoor" or "beach"
#'
#' @return data.frame with columns message (the validation message), file_line_number (the corresponding line number in the DataVolley file), video_time, and file_line (the actual line from the DataVolley file).
#'
#' @seealso \code{\link{read_dv}}
#'
#' @examples
#' \dontrun{
#'   x <- read_dv(dv_example_file(), insert_technical_timeouts = FALSE)
#'   xv <- validate_dv(x)
#'
#'   ## specifying "PP" as the setter tip code
#'   ## front-row attacks (using this code) by a back-row player won't be flagged as errors
#'   xv <- validate_dv(x, options = list(setter_tip_codes = c("PP"))) 
#' }
#'
#' @export
validate_dv <- function(x, validation_level = 2, options = list(), file_type = "indoor") {
    assert_that(is.numeric(validation_level) && validation_level %in% 0:3)
    assert_that(is.list(options))
    assert_that(is.string(file_type))
    file_type <- match.arg(tolower(file_type), c("indoor", "beach"))

    team_player_num <- if (grepl("beach", file_type)) 1:2 else 1:6

    out <- data.frame(file_line_number=integer(), video_time=integer(), message=character(), file_line=character(), severity=numeric(), stringsAsFactors=FALSE)
    chk_df <- function(chk, msg, severity = 2) {
        vt <- video_time_from_raw(x$raw[chk$file_line_number])
        data.frame(file_line_number=chk$file_line_number, video_time=vt, message=msg, file_line=x$raw[chk$file_line_number], severity=severity, stringsAsFactors=FALSE)
    }
    if (validation_level<1) return(out)

    ## metadata checks
    for (py in c("players_h", "players_v")) {
        plyrs <- x$meta[[py]]
        tempid <- plyrs$player_id[!is.na(plyrs$player_id)]
        if (any(duplicated(tempid))) {
            dpids <- tempid[duplicated(tempid)]
            for (dpid in unique(dpids)) {
                idx <- plyrs$player_id %eq% dpid
                this_players <- paste0(plyrs$name[idx], " [jersey number ", plyrs$number[idx], "]", collapse=", ")
                msg <- if (py == "players_h") paste0("Home team (", home_team(x), ")") else paste0("Visiting team (", visiting_team(x), ")")
                msg <- paste0(msg, " players ", this_players, " have the same player ID (", dpid, ")")
                out <- rbind(out, data.frame(file_line_number = NA, video_time = NA, message = msg, file_line = NA_character_, severity = 3, stringsAsFactors = FALSE))
            }
        }
    }
    if (file_type == "indoor") {
        ## check for missing player roles
        for (py in c("players_h", "players_v")) {
            plyrs <- x$meta[[py]]
            idx <- which(is.na(plyrs$role))
            ## of these, the players who appear in the plays data or have a special role (libero, captain)
            ##        idx1 <- idx[vapply(idx, function(z) any(x$plays$player_id %eq% plyrs$player_id[z]) || (!is.na(plyrs$special_role[z]) && nzchar(plyrs$special_role[z])), FUN.VALUE = TRUE, USE.NAMES = FALSE)]
            ## can't decide whether to treat players who appear in the plays data differently to those who do not: for now treat the same
            idx1 <- idx
            if (length(idx1) > 0) {
                this_players <- paste0(plyrs$name[idx1], collapse=", ")
                msg <- if (py == "players_h") paste0("Home team (", home_team(x), ")") else paste0("Visiting team (", visiting_team(x), ")")
                if (length(idx1) > 1) {
                    wd1 <- " players "
                    wd2 <- " have "
                } else {
                    wd1 <- " player "
                    wd2 <- " has "
                }
                msg <- paste0(msg, wd1, this_players, wd2, "no position (opposite/outside/etc) assigned in the players list")
                out <- rbind(out, data.frame(file_line_number = NA, video_time = NA, message = msg, file_line = NA_character_, severity = 3, stringsAsFactors = FALSE))
            }
            ##        ## players who do not appear in the plays data - these missing roles might be less important, but we'll flag them at the same level of severity (just with a different message)
            ##        idx2 <- setdiff(idx, idx1)
            ##        if (length(idx2) > 0) {
            ##            this_players <- paste0(plyrs$name[idx2], collapse=", ")
            ##            msg <- if (py == "players_h") paste0("Home team (", home_team(x), ")") else paste0("Visiting team (", visiting_team(x), ")")
            ##            if (length(idx2) > 1) {
            ##                wd1 <- " players "
            ##                wd2 <- " have "
            ##            } else {
            ##                wd1 <- " player "
            ##                wd2 <- " has "
            ##            }
            ##            msg <- paste0(msg, wd1, this_players, wd2, "no position (opposite/outside/etc) assigned in the players list. Note that these players do not appear in the plays data, so probably did not take the court during the match")
            ##            out <- rbind(out, data.frame(file_line_number = NA, video_time = NA, message = msg, file_line = NA_character_, severity = 3, stringsAsFactors = FALSE))
            ##        }
        }
    }
    plays <- plays(x)

    ## reception to follow serve
    ## commented out, have the same check elsewhere
    ##idx <- which(plays$skill %eq% "Serve" & !plays$evaluation %in% c("Error"))##, "Ace"))
    ##idx2 <- idx[!is.na(plays$skill[idx+1]) & !plays$skill[idx+1] %in% c("Reception", "Rotation error")]##plays$evaluation[idx] %eq% "Ace" & 
    ####idx2 <- idx[!plays$skill[idx+1] %eq% "Reception"]
    ##if (length(idx2)>0) {
    ##    out <- rbind(out, chk_df(plays[idx2, ], "Serve was not followed by a reception", severity=3))
    ##}
    ## multiple serves or receptions per point
    #idx <- which(plays$skill %eq% "Serve")
    #idx <- idx[duplicated(x$point_id[idx])]
    ##x %>% group_by(point_id, match_id) %>% dplyr::summarize(r2=sum(skill %eq% "Reception")>1, s2=sum(skill %eq% "Serve")>1) %>% filter(r2|s2)
    
    ## receive type must match serve type
    idx <- which(plays$skill %eq% "Reception")
    idx <- idx[plays$skill[idx-1] %eq% "Serve"] ## just in case have reception not preceded by serve
    idx2 <- idx[plays$skill_type[idx]!=paste0(plays$skill_type[idx-1], " reception") & (plays$skill_type[idx]!="Unknown serve reception type" & plays$skill_type[idx-1]!="Unknown serve type")]
    if (length(idx2)>0)
        out <- rbind(out, chk_df(plays[idx2, ], paste0("Reception type (", plays$skill_type[idx2], ") does not match serve type (", plays$skill_type[idx2-1], ")")))
    if (validation_level>2) {
        ## reception zones must match serve zones
        ## start zones mismatch, but not any missing
        idx2 <- idx[(!plays$start_zone[idx] %eq% plays$start_zone[idx-1]) & !is.na(plays$start_zone[idx]) & !is.na(plays$start_zone[idx-1])]
        if (length(idx2)>0)
            out <- rbind(out,chk_df(plays[idx2,],paste0("Reception start zone (",plays$start_zone[idx2],") does not match serve start zone (",plays$start_zone[idx2-1],")"),severity=1))
        ## end zones mismatch, but not any missing
        idx2 <- idx[(!plays$end_zone[idx] %eq% plays$end_zone[idx-1]) & !is.na(plays$end_zone[idx]) & !is.na(plays$end_zone[idx-1])]
        if (length(idx2)>0)
            out <- rbind(out,chk_df(plays[idx2,],paste0("Reception end zone (",plays$end_zone[idx2],") does not match serve end zone (",plays$end_zone[idx2-1],")"),severity=1))
        ## end zones mismatch, but not any missing
        idx2 <- idx[(!plays$end_subzone[idx] %eq% plays$end_subzone[idx-1]) & !is.na(plays$end_subzone[idx]) & !is.na(plays$end_subzone[idx-1])]
        if (length(idx2)>0)
            out <- rbind(out,chk_df(plays[idx2,],paste0("Reception end sub-zone (",plays$end_subzone[idx2],") does not match serve end sub-zone (",plays$end_subzone[idx2-1],")"),severity=1))

        ## attack type must match set type
        idx <- which(plays$skill %eq% "Attack")
        idx <- idx[plays$skill[idx-1] %eq% "Set"]
        idx <- idx[plays$skill_type[idx]!=gsub(" set"," attack",plays$skill_type[idx-1])]
        if (length(idx)>0)
            out <- rbind(out,chk_df(plays[idx,],paste0("Attack type (",plays$skill_type[idx],") does not match set type (",plays$skill_type[idx-1],")")))

        ## block type must match attack type
        idx <- which(plays$skill %eq% "Block")
        idx <- idx[plays$skill[idx-1] %eq% "Attack"]
        idx <- idx[plays$skill_type[idx]!=gsub(" attack"," block",plays$skill_type[idx-1])]
        if (length(idx)>0)
            out <- rbind(out,chk_df(plays[idx,],paste0("Block type (",plays$skill_type[idx],") does not match attack type (",plays$skill_type[idx-1],")")))

        ## dig type must match attack type
        idx <- which(plays$skill %eq% "Dig")
        idx <- idx[plays$skill[idx-1] %eq% "Attack"]
        idx <- idx[plays$skill_type[idx]!=gsub(" attack"," dig",plays$skill_type[idx-1])]
        if (length(idx)>0)
            out <- rbind(out,chk_df(plays[idx,],paste0("Dig type (",plays$skill_type[idx],") does not match attack type (",plays$skill_type[idx-1],")")))
    }

    if (file_type == "indoor") {
        ## front-row attacking player isn't actually in front row
        ## find front-row players for each attack
        ignore_codes <- options$setter_tip_codes
        if (!is.null(ignore_codes)) {
            if (!is.character(ignore_codes)) ignore_codes <- NULL
        }
        if (!is.null(ignore_codes)) ignore_codes <- na.omit(ignore_codes)
        attacks <- plays[plays$skill %eq% "Attack", ]
        if (nrow(attacks) > 0) {
            for (p in 1:6) attacks[, paste0("attacker_", p)] <- NA
            idx <- attacks$home_team==attacks$team
            attacks[idx, paste0("attacker_", 1:6)] <- attacks[idx, paste0("home_p", 1:6)]
            attacks[!idx, paste0("attacker_", 1:6)] <- attacks[!idx, paste0("visiting_p", 1:6)]
            chk <- attacks[attacks$start_zone %in% c(2,3,4) & (!attacks$attack_code %in% ignore_codes) & (attacks$player_number==attacks$attacker_1 | attacks$player_number==attacks$attacker_5 | attacks$player_number==attacks$attacker_6),]
            if (nrow(chk)>0)
                out <- rbind(out,chk_df(chk,"Back-row player made an attack from a front-row zone",severity=3))

            ## and vice-versa: attack starting from back row by a front-row player
            chk <- attacks[attacks$start_zone %in% c(5,6,7,8,9,1) & (attacks$player_number==attacks$attacker_2 | attacks$player_number==attacks$attacker_3 | attacks$player_number==attacks$attacker_4),]
            if (nrow(chk)>0)
                out <- rbind(out,chk_df(chk,"Front-row player made an attack from a back-row zone (legal, but possibly a scouting error)",severity=2))
            ## those are probably less of an issue than a back-row player making a front row attack. A front-row player making a back row attack is not illegal, just inconsistent
        }
        ## back row player blocking
        chk <- (plays$skill %eq% "Block") &
            (((plays$team %eq% plays$home_team) & (plays$player_number %eq% plays$home_p5 | plays$player_number %eq% plays$home_p6 | plays$player_number %eq% plays$home_p1)) |
             ((plays$team %eq% plays$visiting_team) & (plays$player_number %eq% plays$visiting_p5 | plays$player_number %eq% plays$visiting_p6 | plays$player_number %eq% plays$visiting_p1)))
        if (any(chk))
            out <- rbind(out,data.frame(file_line_number=plays$file_line_number[chk],video_time=video_time_from_raw(x$raw[plays$file_line_number[chk]]),message="Block by a back-row player",file_line=x$raw[plays$file_line_number[chk]],severity=3,stringsAsFactors=FALSE))

        ## for the next two, not sure if we should assume rotation errors should be aces or not
        ##  so the default rotation_error_is_ace for each is set to not warn when rotation errors are present
        ## serves that should be coded as aces, but were not
        find_should_be_aces <- function(rally,rotation_error_is_ace=FALSE) {
            sv <- which(rally$skill=="Serve")
            if (length(sv)==1) {
                was_ace <- (rally$team[sv] %eq% rally$point_won_by[sv]) & (!"Reception" %in% rally$skill || rally$evaluation[rally$skill %eq% "Reception"] %eq% "Error") & (rotation_error_is_ace | !rally$skill[sv + 1] %eq% "Rotation error")
                if (!rotation_error_is_ace && (rally$skill[sv + 1] %eq% "Rotation error")) was_ace <- FALSE ## to avoid warnings
                ## also skip this check if the next skill not reception (or rotation error), since that's likely to affect this
                if (!is.na(rally$skill[sv + 1]) && (!rally$skill[sv + 1] %in% c("Rotation error","Reception"))) was_ace <- FALSE
                if (was_ace & !identical(rally$evaluation[sv], "Ace")) {
                    TRUE
                } else {
                    FALSE
                }
            } else {
                NA
            }
        }
        pid <- ddply(plays,"point_id",find_should_be_aces)
        pid <- pid$point_id[!is.na(pid$V1) & pid$V1]
        chk <- plays$skill %eq% "Serve" & plays$point_id %in% pid
        if (any(chk))
            out <- rbind(out,data.frame(file_line_number=plays$file_line_number[chk],video_time=video_time_from_raw(x$raw[plays$file_line_number[chk]]),message="Winning serve not coded as an ace",file_line=x$raw[plays$file_line_number[chk]],severity=3,stringsAsFactors=FALSE))
        ## and vice-versa: serves that were coded as aces, but should not have been
        find_should_not_be_aces <- function(rally,rotation_error_is_ace=TRUE) {
            ## by default assume rotation errors should be aces here (opposite to above)
            ## so that warnings won't be issued when rotation errors present
            sv <- which(rally$skill=="Serve")
            if (length(sv)==1) {
                was_ace <- (rally$team[sv] %eq% rally$point_won_by[sv]) & (!"Reception" %in% rally$skill || rally$evaluation[rally$skill %eq% "Reception"] %eq% "Error") & (rotation_error_is_ace | !rally$skill[sv + 1] %eq% "Rotation error")
                if (rotation_error_is_ace && (rally$skill[sv + 1] %eq% "Rotation error")) was_ace <- TRUE ## to avoid warnings
                if (!was_ace & identical(rally$evaluation[sv],"Ace")) {
                    TRUE
                } else {
                    FALSE
                }
            } else {
                NA
            }
        }
        pid <- ddply(plays,"point_id",find_should_not_be_aces)
        pid <- pid$point_id[!is.na(pid$V1) & pid$V1]
        chk <- plays$skill %eq% "Serve" & plays$point_id %in% pid
        if (any(chk))
            out <- rbind(out,data.frame(file_line_number=plays$file_line_number[chk],video_time=video_time_from_raw(x$raw[plays$file_line_number[chk]]),message="Non-winning serve was coded as an ace",file_line=x$raw[plays$file_line_number[chk]],severity=3,stringsAsFactors=FALSE))

        ## server not in position 1
        chk <- (plays$skill %eq% "Serve") & (((plays$team %eq% plays$home_team) & (!plays$player_number %eq% plays$home_p1)) | ((plays$team %eq% plays$visiting_team) & (!plays$player_number %eq% plays$visiting_p1)))
        if (any(chk))
            out <- rbind(out,data.frame(file_line_number=plays$file_line_number[chk],video_time=video_time_from_raw(x$raw[plays$file_line_number[chk]]),message="Serving player not in position 1",file_line=x$raw[plays$file_line_number[chk]],severity=3,stringsAsFactors=FALSE))
    }

    ## number of blockers (for an attack) should be >=1 if it is followed by a block
    idx <- which(plays$skill %eq% "Block")-1 ## -1 to be on the attack
    idx2 <- idx[plays$skill[idx] %eq% "Attack" & (!plays$team[idx] %eq% plays$team[idx+1]) & is.na(plays$num_players[idx])]
    if (length(idx2)>0)
        out <- rbind(out,chk_df(plays[idx2,],"Attack (which was blocked) does not have number of blockers recorded",severity=1))

    idx2 <- idx[plays$skill[idx] %eq% "Attack" & (!plays$team[idx] %eq% plays$team[idx+1]) & (plays$num_players[idx] %eq% "No block")]
    if (length(idx2)>0)
        out <- rbind(out,chk_df(plays[idx2,],"Attack (which was followed by a block) has \"No block\" recorded for number of players",severity=3))

    ## winning attack not coded as such
    ## this one seems to be too problematic: e.g. can have attack that was hit out, but block net touch, so attack should NOT be coded as winning attack
    #idx <- which(plays$skill %eq% "Attack") ## +1 to be on the next skill
    #idx2 <- idx[!plays$evaluation[idx] %eq% "Winning attack" & !plays$team[idx] %eq% plays$team[idx+1] & plays$evaluation[idx+1] %eq% "Error" & !is.na(plays$skill[idx+1])]
    #if (length(idx2)>0)
    #    out <- rbind(out,chk_df(plays[idx2,],"Winning attack was not recorded as such",severity=3))

    ## player not in recorded rotation making a play (other than by libero)
    liberos_v <- x$meta$players_v$number[grepl("L",x$meta$players_v$special_role)]
    liberos_h <- x$meta$players_h$number[grepl("L",x$meta$players_h$special_role)]
    pp <- plays[plays$skill %in% c("Serve","Attack","Block","Dig","Freeball","Reception","Set"), ]
    ##pp$labelh <- "home_team"
    ##pp$labelv <- "visiting_team"
    ##temp <- ldply(1:nrow(pp), function(z) {
    ##    fcols <- if (pp$home_team[z] %eq% pp$team[z]) c(paste0("home_p", team_player_num), "labelh") else c(paste0("visiting_p", team_player_num), "labelv")
    ##    out <- pp[z,fcols]
    ##    names(out) <- c(paste0("player", team_player_num), "which_team")
    ##    out
    ##})
    ## faster code, avoid the ldply
    temp <- pp[, paste0("visiting_p", team_player_num)]
    names(temp) <- paste0("player", team_player_num)
    idx <- pp$team %eq% pp$home_team
    temp[idx, ] <- pp[idx, paste0("home_p", team_player_num)]
    temp$which_team <- "visiting_team"
    temp$which_team[idx] <- "home_team"
    temp <- as.data.frame(temp, stringsAsFactors = FALSE)
    rownames(temp) <- NULL
    ##rownames(temp) <- NULL
    ##if (!identical(temp, temp2)) {
    ##    cat(str(temp))
    ##    cat(str(temp2))
    ##    cat(str(all.equal(temp, temp2)))
    ##    stop("no")
    ##}
    chk <- sapply(1:nrow(pp),function(z) !pp$player_number[z] %in% (if (temp$which_team[z]=="home_team") liberos_h else liberos_v) & (!pp$player_number[z] %in% temp[z,]))
    if (any(chk))
        out <- rbind(out,data.frame(file_line_number=pp$file_line_number[chk],video_time=video_time_from_raw(x$raw[pp$file_line_number[chk]]),message="The listed player is not on court in this rotation",file_line=x$raw[pp$file_line_number[chk]],severity=3,stringsAsFactors=FALSE))

    if (file_type == "indoor") {
        ## liberos doing stuff they oughn't to be doing
        if (length(liberos_h)>0) {
            chk <- (plays$skill %in% c("Serve","Attack","Block")) & (plays$home_team %eq% plays$team) & (plays$player_number %in% liberos_h)
            if (any(chk))
                out <- rbind(out,data.frame(file_line_number=plays$file_line_number[chk],video_time=video_time_from_raw(x$raw[plays$file_line_number[chk]]),message=paste0("Player designated as libero was recorded making a ",tolower(plays$skill[chk])),file_line=x$raw[plays$file_line_number[chk]],severity=3,stringsAsFactors=FALSE))
        }
        if (length(liberos_v)>0) {
            chk <- (plays$skill %in% c("Serve","Attack","Block")) & (plays$visiting_team %eq% plays$team) & (plays$player_number %in% liberos_v)
            if (any(chk))
                out <- rbind(out,data.frame(file_line_number=plays$file_line_number[chk],video_time=video_time_from_raw(x$raw[plays$file_line_number[chk]]),message=paste0("Player designated as libero was recorded making a ",tolower(plays$skill[chk])),file_line=x$raw[plays$file_line_number[chk]],severity=3,stringsAsFactors=FALSE))
        }
        ## TO DO, perhaps: check for liberos making a front-court set that is then attacked
    }
    
    ## duplicate entries with same skill and evaluation code for the same player
    idx <- which((plays$evaluation_code[-1] %eq% plays$evaluation_code[-nrow(plays)]) &
                 (plays$skill[-1] %eq% plays$skill[-nrow(plays)]) &
                 (plays$team[-1] %eq% plays$team[-nrow(plays)]) &
                 (plays$player_number[-1] %eq% plays$player_number[-nrow(plays)])
                 )+1
    if (length(idx)>0)
        out <- rbind(out,data.frame(file_line_number=plays$file_line_number[idx],video_time=video_time_from_raw(x$raw[plays$file_line_number[idx]]),message="Repeated row with same skill and evaluation_code for the same player",file_line=x$raw[plays$file_line_number[idx]],severity=3,stringsAsFactors=FALSE))

    ## consecutive actions by the same player
    ## be selective about which skill sequences count here, because some scouts might record duplicate skills for the same player (e.g. reception and set) for one physical action
    ## also don't bother picking up illegal skill sequences, they will be picked up elsewhere
    idx0 <- 1:(nrow(plays)-1); idx0_next <- 2:nrow(plays)
    idx <- which(plays$player_id[idx0] %eq% plays$player_id[idx0_next] &
        ((plays$skill[idx0] %eq% "Reception" & plays$skill[idx0_next] %in% c("Attack")) |
         (plays$skill[idx0] %eq% "Set" & plays$skill[idx0_next] %eq% "Block")))
    if (length(idx)>0)
        out <- rbind(out,chk_df(plays[idx+1,],"Consecutive actions by the same player",severity=3))
    
    ## point not awarded to right team following error
    chk <- (plays$evaluation_code %eq% "=" | (plays$skill %eq% "Block" & grepl("invasion", plays$evaluation, ignore.case=TRUE))) &  ## error or block Invasion
            (plays$team %eq% plays$point_won_by)
    if (any(chk))
        out <- rbind(out,data.frame(file_line_number=plays$file_line_number[chk],video_time=video_time_from_raw(x$raw[plays$file_line_number[chk]]),message="Point awarded to incorrect team following error (or \"error\" evaluation incorrect)",file_line=x$raw[plays$file_line_number[chk]],severity=3,stringsAsFactors=FALSE))
    
    ## point not awarded to right team following win
    chk <- (plays$skill %in% c("Serve","Attack","Block") & plays$evaluation_code %eq% "#") &  ## ace or winning attack or block
            (!plays$team %eq% plays$point_won_by)
    if (any(chk))
        out <- rbind(out,data.frame(file_line_number=plays$file_line_number[chk],video_time=video_time_from_raw(x$raw[plays$file_line_number[chk]]),message=paste0("Point awarded to incorrect team (or \"",plays$evaluation[chk],"\" evaluation incorrect)"),file_line=x$raw[plays$file_line_number[chk]],severity=3,stringsAsFactors=FALSE))

    ## check scores columns against point_won_by entries
    temp <- plays[!is.na(plays$set_number) & !is.na(plays$point_won_by),]
    temp <- ddply(temp,c("point_id"),.fun=function(z) tail(z[,c("set_number","home_team","visiting_team","home_team_score","visiting_team_score","point_won_by","file_line_number")],1))
    temp <- temp[order(temp$point_id),]
    temp$won_by_home <- temp$point_won_by==temp$home_team
    ## dplyr call: temp <- plays %>% group_by(point_id) %>% do(.[,c("set_number","home_team","visiting_team","home_team_score","visiting_team_score","point_won_by")] %>% filter(!is.na(set_number)) %>% distinct()) %>% ungroup %>% filter(!is.na(point_won_by)) %>% arrange(point_id) %>% mutate(won_by_home=point_won_by==home_team)
    temp$home_team_diff <- diff(c(0,temp$home_team_score))
    temp$visiting_team_diff <- diff(c(0,temp$visiting_team_score))
    temp$point_lost_by <- temp$home_team
    idx <- temp$point_won_by %eq% temp$home_team
    temp$point_lost_by[idx] <- temp$visiting_team[idx]
    temp$ok <- TRUE
    idx <- temp$won_by_home
    temp$ok[idx] <- temp$home_team_diff[idx]==1
    idx <- !temp$won_by_home
    temp$ok[idx] <- temp$visiting_team_diff[idx]==1
    ## these won't be valid for first point of each set other than first set
    for (ss in 2:5) {
        idx <- temp$set_number==ss
        if (any(idx)) {
            idx <- min(which(idx)) ## first point of set ss
            temp$ok[idx] <- (temp$won_by_home[idx] && temp$home_team_score[idx]==1 && temp$visiting_team_score[idx]==0) || (!temp$won_by_home[idx] && temp$home_team_score[idx]==0 && temp$visiting_team_score[idx]==1)
        }
    }
    if (any(is.na(temp$point_won_by))) {
        ## should not see this
        ## just assume were ok
        temp$ok[is.na(temp$point_won_by)] <- TRUE
    }
    temp <- temp[!temp$ok,]
    if (nrow(temp)>0) {
        for (chk in seq_len(nrow(temp))) {
            out <- rbind(out,data.frame(file_line_number=temp$file_line_number[chk],video_time=video_time_from_raw(x$raw[temp$file_line_number[chk]]),message=paste0("Point assigned to incorrect team or scores incorrect (point was won by ",temp$point_won_by[chk]," but score was incremented for ",temp$point_lost_by[chk],")"),file_line=x$raw[temp$file_line_number[chk]],severity=3,stringsAsFactors=FALSE))
        }
    }

    ## scores not in proper sequence
    ## a team's score should never increase by more than 1 at a time. May be negative (change of sets)
    temp <- plays[,c("home_team_score","visiting_team_score","set_number")]
    temp <- apply(temp,2,diff)
    ## either score increases by more than one, or (decreases and not end of set)
    chk <- which((temp[,1]>1 | temp[,2]>1) | ((temp[,1]<0 | temp[,2]<0) & !(is.na(temp[,3]) | temp[,3]>0)))
    ##chk <- diff(plays$home_team_score)>1 | diff(plays$visiting_team_score)>1
    ##if (any(chk))
    if (length(chk)>0) {
        chk <- chk+1
        out <- rbind(out,data.frame(file_line_number=plays$file_line_number[chk],video_time=video_time_from_raw(x$raw[plays$file_line_number[chk]]),message="Scores do not follow proper sequence (note that the error may be in the point before this one)",file_line=x$raw[plays$file_line_number[chk]],severity=3,stringsAsFactors=FALSE))
    }

    ## check for incorrect rotation changes
    rotleft <- function(x) if (is.data.frame(x)) {out <- cbind(x[,-1],x[,1]); names(out) <- names(x); out} else c(x[-1],x[1])
    isrotleft <- function(x,y) all(as.numeric(rotleft(x))==as.numeric(y)) ## is y a left-rotated version of x?
    for (tm in c("*","a")) {
        rot_cols <- if (tm=="a") paste0("visiting_p", team_player_num) else paste0("home_p", team_player_num)
        temp <- plays[!tolower(plays$skill) %eq% "technical timeout",]
        rx <- temp[,rot_cols]
        idx <- unname(c(FALSE,rowSums(abs(apply(rx,2,diff)))>0)) ## rows where rotation changed from previous
        idx[is.na(idx)] <- FALSE ## end of set, etc, ignore
        idx[temp$substitution] <- FALSE ## subs, ignore these here and they will be checked in the next section
        for (k in which(idx)) {
            if (!isrotleft(rx[k-1,],rx[k,]))
                out <- rbind(out,data.frame(file_line_number=temp$file_line_number[k],video_time=video_time_from_raw(x$raw[temp$file_line_number[k]]),message=paste0(if (tm=="a") "Visiting" else "Home"," team rotation has changed incorrectly"),file_line=x$raw[temp$file_line_number[k]],severity=3,stringsAsFactors=FALSE))
        }
    }
    
    ## check that players changed correctly on substitution
    ## e.g. *c02:01 means player 2 replaced by player 1
    idx <- which(plays$substitution & grepl("^.c",plays$code))
    idx <- idx[idx>2 & idx<(nrow(plays)-1)] ## discard anything at the start or end of the file
    rot_errors <- list()
    for (k in idx) {
        rot_cols <- if (grepl("^a",plays$code[k])) paste0("visiting_p", team_player_num) else paste0("home_p", team_player_num)
        prev_rot <- plays[k-1,rot_cols]
        if (any(is.na(prev_rot))) {
            if (k>2) prev_rot <- plays[k-2,rot_cols]
        }
        if (any(is.na(prev_rot))) next ## could perhaps search further backwards, but should not need to
        ## have only seen one NA rot row in sequence in files so far
        
        new_rot <- plays[k+1,rot_cols]
        if (any(is.na(new_rot))) {
            if (k<(nrow(plays)-2)) new_rot <- plays[k+2,rot_cols]
        }
        if (any(is.na(new_rot))) next
        
        if (all(new_rot==prev_rot)) {
            ## players did not change
            rot_errors[[length(rot_errors)+1]] <- data.frame(file_line_number=plays$file_line_number[k],video_time=video_time_from_raw(x$raw[plays$file_line_number[k]]),message=paste0("Player lineup did not change after substitution: was the sub recorded incorrectly?"),file_line=x$raw[plays$file_line_number[k]],severity=3,stringsAsFactors=FALSE)
            next
        }
        sub_out <- as.numeric(sub(":.*$","",sub("^.c","",plays$code[k]))) ## outgoing player
        sub_in <- as.numeric(sub("^.*:","",plays$code[k])) ## incoming player
        if (!sub_out %in% prev_rot || !sub_in %in% new_rot || sub_in %in% prev_rot || sub_out %in% new_rot) {
            rot_errors[[length(rot_errors)+1]] <- data.frame(file_line_number=plays$file_line_number[k],video_time=video_time_from_raw(x$raw[plays$file_line_number[k]]),message=paste0("Player lineup conflicts with recorded substitution: was the sub recorded incorrectly?"),file_line=x$raw[plays$file_line_number[k]],severity=3,stringsAsFactors=FALSE)
            next
        }
    }
    if (length(rot_errors)>0) out <- rbind(out,do.call(rbind,rot_errors))
    out <- out[4-out$severity<=validation_level,]
    out[,setdiff(names(out),"severity")]
}
