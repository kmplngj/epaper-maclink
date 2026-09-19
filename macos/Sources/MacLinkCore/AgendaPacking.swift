import Foundation

public struct AgendaPlacement {
    public let day:Int
    public let row:Int
    public let lane:Int
    public let y:Int
    public let continuation:Bool
}
public struct AgendaFit {
    public let placements:[AgendaPlacement]
    public let completeDays:Int
}
public enum AgendaPacking {
    /// Lay out a chronological prefix of COMPLETE days. Trial placement is rolled
    /// back if any event in a day cannot fit. Rows may continue in the second lane.
    public static func fit(dayRows:[[Int]],laneStarts:[Int],bottom:Int,gap:Int=5)->AgendaFit {
        guard !laneStarts.isEmpty else { return AgendaFit(placements:[],completeDays:0) }
        var lane=0,y=laneStarts[0],result:[AgendaPlacement]=[],complete=0
        for (day,rows) in dayRows.enumerated() {
            var trialLane=lane,trialY=y,trial:[AgendaPlacement]=[]
            var fits=true
            for (row,height) in rows.enumerated() {
                while trialY+height>bottom && trialLane+1<laneStarts.count { trialLane+=1;trialY=laneStarts[trialLane] }
                if trialY+height>bottom { fits=false;break }
                trial.append(AgendaPlacement(day:day,row:row,lane:trialLane,y:trialY,continuation:row>0 && (trial.last?.lane != trialLane)))
                trialY+=height
            }
            if !fits { break }
            result+=trial;complete+=1;lane=trialLane;y=trialY+gap
        }
        return AgendaFit(placements:result,completeDays:complete)
    }
}
